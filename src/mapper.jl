struct KeyFrame
    id::Int64
    left_pyramid::Union{Nothing, LKPyramid{Vector{Matrix{Gray{Float64}}}, LKCache}}
    right_image::Union{Nothing, Matrix{Gray{Float64}}}
end

mutable struct Mapper
    params::Params
    map_manager::MapManager
    estimator::Estimator

    current_frame::Frame
    keyframe_queue::Vector{KeyFrame}
    right_pyramid::LKPyramid
    geev_cache::GEEV4x4Cache

    exit_required::Bool
    new_kf_available::Bool

    estimator_thread
    queue_lock::ReentrantLock
end

function Mapper(params::Params, map_manager::MapManager, frame::Frame)
    estimator = Estimator(map_manager, params)
    estimator_thread = Threads.@spawn run!(estimator)
    @debug "[MP] Launched estimator thread."
    empty_pyr = LKPyramid(
        [Matrix{Gray{Float64}}(undef, 0, 0)],
        nothing, nothing, nothing, nothing, nothing, nothing)
    Mapper(
        params, map_manager, estimator,
        frame, KeyFrame[], empty_pyr, GEEV4x4Cache(),
        false, false, estimator_thread, ReentrantLock())
end

function run!(mapper::Mapper)
    while !mapper.exit_required
        succ, kf = get_new_kf!(mapper)
        if !succ
            sleep(1e-2)
            continue
        end

        new_keyframe = get_keyframe(mapper.map_manager, kf.id)
        new_keyframe ≡ nothing && @error "[MP] Got invalid frame $(kf.id) from Map"

        if mapper.params.stereo
            try
                t1 = time()
                if has_gradients(mapper.right_pyramid)
                    update!(mapper.right_pyramid, kf.right_image)
                else
                    mapper.right_pyramid = LKPyramid(
                        kf.right_image, mapper.params.pyramid_levels;
                        σ=mapper.params.pyramid_σ, reusable=true)
                end
                optical_flow_matching!(
                    mapper.map_manager, new_keyframe,
                    kf.left_pyramid, mapper.right_pyramid, true)
                t2 = time()
                @debug "[MP] Stereo Matching ($(t2 - t1) sec): $(new_keyframe.nb_stereo_kpts) Keypoints"
            catch e
                showerror(stdout, e)
                display(stacktrace(catch_backtrace()))
            end

            if new_keyframe.nb_stereo_kpts > 0
                lock(mapper.map_manager.map_lock)
                try
                    t1 = time()
                    triangulate_stereo!(
                        mapper.map_manager, new_keyframe,
                        mapper.params.max_reprojection_error, mapper.geev_cache)
                    t2 = time()
                    @debug "[MP] Stereo Triangulation ($(t2 - t1) sec)."
                catch e
                    showerror(stdout, e)
                    display(stacktrace(catch_backtrace()))
                finally
                    unlock(mapper.map_manager.map_lock)
                end
            end

            # vimage = RGB{Float64}.(kf.right_image)
            # draw_keypoints!(vimage, new_keyframe; right=true)
            # Images.save("/home/pxl-th/projects/slam-data/images/frame-$(new_keyframe.id)-right.png", vimage)
        end

        if new_keyframe.nb_2d_kpts > 0 && new_keyframe.kfid > 0
            lock(mapper.map_manager.map_lock)
            try
                t1 = time()
                triangulate_temporal!(
                    mapper.map_manager, new_keyframe,
                    mapper.params.max_reprojection_error, mapper.geev_cache)
                t2 = time()
                @debug "[MP] Temporal Triangulation ($(t2 - t1) sec)."
            catch e
                showerror(stdout, e)
                display(stacktrace(catch_backtrace()))
            finally
                unlock(mapper.map_manager.map_lock)
            end
        end

        # Check if reset is required.
        if mapper.params.vision_initialized
            if kf.id == 1 && new_keyframe.nb_3d_kpts < 30
                @warn "[MP] Bad initialization detected. Resetting!"
                mapper.params.reset_required = true
                mapper |> reset!
                continue
            elseif kf.id < 10 && new_keyframe.nb_3d_kpts < 3
                @warn "[MP] Reset required. Nb 3D points: $(new_keyframe.nb_3d_kpts)."
                mapper.params.reset_required = true
                mapper |> reset!
                continue
            end
        end

        t1 = time()
        update_frame_covisibility!(mapper.map_manager, new_keyframe)
        t2 = time()
        @debug "[MP] Covisibility update ($(t2 - t1) sec)."

        if mapper.params.do_local_matching && kf.id > 0
            t1 = time()
            try
                match_local_map!(mapper, new_keyframe)
            catch e
                showerror(stdout, e)
                display(stacktrace(catch_backtrace()))
            end
            t2 = time()
            @debug "[MP] Local Matching ($(t2 - t1) sec)."
        end

        add_new_kf!(mapper.estimator, new_keyframe)
    end
    mapper.estimator.exit_required = true
    @debug "[MP] Exit required."
    wait(mapper.estimator_thread)
end

function triangulate_stereo!(
    map_manager::MapManager, frame::Frame, max_error, cache::GEEV4x4Cache,
)
    stereo_keypoints = get_stereo_keypoints(frame)
    if isempty(stereo_keypoints)
        @warn "[MP] No stereo keypoints to triangulate."
        return
    end

    P1 = to_4x4(frame.camera.K) * SMatrix{4, 4, Float64, 16}(I)
    P2 = to_4x4(frame.right_camera.K) * frame.right_camera.Ti0

    n_good = 0
    for kp in stereo_keypoints
        kp.is_3d && continue
        mp = get_mappoint(map_manager, kp.id)
        mp ≡ nothing &&
            (remove_mappoint_obs!(map_manager, kp.id, frame.kfid); continue)
        mp.is_3d && continue

        left_point = triangulate(
            kp.undistorted_pixel[[2, 1]], kp.right_undistorted_pixel[[2, 1]],
            P1, P2, cache)
        left_point *= 1.0 / left_point[4]
        left_point[3] < 0.1 && (remove_stereo_keypoint!(frame, kp.id); continue)

        right_point = frame.right_camera.Ti0 * left_point
        right_point[3] < 0.1 && (remove_stereo_keypoint!(frame, kp.id); continue)

        left_projection = project(frame.camera, left_point[1:3])
        lrepr = norm(kp.undistorted_pixel .- left_projection)
        lrepr > max_error && (remove_stereo_keypoint!(frame, kp.id); continue)

        right_projection = project(frame.right_camera, right_point[1:3])
        rrepr = norm(kp.right_undistorted_pixel .- right_projection)
        rrepr > max_error && (remove_stereo_keypoint!(frame, kp.id); continue)

        wpt = project_camera_to_world(frame, left_point)[1:3]
        update_mappoint!(map_manager, kp.id, wpt)
        n_good += 1
    end
end

function triangulate_temporal!(
    map_manager::MapManager, frame::Frame, max_error, cache::GEEV4x4Cache,
)
    keypoints = get_2d_keypoints(frame)
    if isempty(keypoints)
        @warn "[MP] No 2D keypoints to triangulate."
        return
    end

    K = to_4x4(frame.camera.K)
    # P1 - previous Keyframe, P2 - this `frame`.
    P1 = K * SMatrix{4, 4, Float64, 16}(I)
    P2 = K * SMatrix{4, 4, Float64, 16}(I)

    good = 0
    rel_kfid = -1
    # frame -> observer key frame.
    rel_pose::SMatrix{4, 4, Float64, 16} = SMatrix{4, 4, Float64, 16}(I)
    rel_pose_inv::SMatrix{4, 4, Float64, 16} = SMatrix{4, 4, Float64, 16}(I)

    for kp in keypoints
        @assert !kp.is_3d

        map_point = get_mappoint(map_manager, kp.id)
        map_point ≡ nothing &&
            (remove_mappoint_obs!(map_manager, kp.id, frame.kfid); continue)
        map_point.is_3d && continue

        # Get first KeyFrame id from the set of mappoint observers.
        observers = get_observers(map_point)
        length(observers) < 2 && continue
        kfid = observers[1]
        frame.kfid == kfid && continue

        observer_kf = get_keyframe(map_manager, kfid)
        if observer_kf ≡ nothing
            @error "[MP] Missing observer for triangulation."
            continue
        end

        # Compute relative motion between new KF & observer KF.
        # Don't recompute if the frame's ids don't change.
        if rel_kfid != kfid
            rel_pose = observer_kf.cw * frame.wc
            rel_pose_inv = inv(SE3, rel_pose)
            rel_kfid = kfid
            P2 = K * rel_pose_inv
        end

        observer_kp = get_keypoint(observer_kf, kp.id)
        observer_kp ≡ nothing && continue
        obup = observer_kp.undistorted_pixel
        kpup = kp.undistorted_pixel

        parallax = norm(
            obup .- project(frame.camera, rel_pose[1:3, 1:3] * kp.position))

        left_point = triangulate(obup[[2, 1]], kpup[[2, 1]], P1, P2, cache)
        left_point *= 1.0 / left_point[4]
        left_point[3] < 0.1 && parallax > 20.0 && (remove_mappoint_obs!(
            map_manager, observer_kp.id, frame.kfid); continue)

        right_point = rel_pose_inv * left_point
        right_point[3] < 0.1 && parallax > 20.0 && (remove_mappoint_obs!(
            map_manager, observer_kp.id, frame.kfid); continue)

        lrepr = norm(project(frame.camera, left_point[1:3]) .- obup)
        lrepr > max_error && parallax > 20.0 && (remove_mappoint_obs!(
            map_manager, observer_kp.id, frame.kfid); continue)

        rrepr = norm(project(frame.camera, right_point[1:3]) .- kpup)
        rrepr > max_error && parallax > 20.0 && (remove_mappoint_obs!(
            map_manager, observer_kp.id, frame.kfid); continue)

        wpt = project_camera_to_world(observer_kf, left_point)[1:3]
        update_mappoint!(map_manager, kp.id, wpt)
        good += 1
    end
end

"""
Try matching keypoints from `frame` with keypoints from frames in its
covisibility graph (aka local map).
"""
function match_local_map!(mapper::Mapper, frame::Frame)
    # Maximum number of MapPoints to track.
    max_nb_mappoints = 10 * mapper.params.max_nb_keypoints
    covisibility_map = get_covisible_map(frame)

    if length(frame.local_map_ids) < max_nb_mappoints
        # Get local map of the oldest covisible KeyFrame and add it
        # to the local map to `frame` to search for MapPoints.
        kfid = collect(keys(covisibility_map))[1]
        co_kf = get_keyframe(mapper.map_manager, kfid)
        while co_kf ≡ nothing && kfid > 0
            kfid -= 1
            co_kf = get_keyframe(mapper.map_manager, kfid)
        end

        co_kf ≢ nothing && union!(frame.local_map_ids, co_kf.local_map_ids)
        # TODO if still not enough, go for another round.
    end

    prev_new_map = do_local_map_matching(
        mapper, frame, frame.local_map_ids;
        max_projection_distance=mapper.params.max_projection_distance,
        max_descriptor_distance=mapper.params.max_descriptor_distance)

    isempty(prev_new_map) || merge_matches(mapper, prev_new_map)
end

function merge_matches(mapper::Mapper, prev_new_map::Dict{Int64, Int64})
    lock(mapper.map_manager.optimization_lock)
    lock(mapper.map_manager.map_lock)
    try
        for (prev_id, new_id) in prev_new_map
            merge_mappoints(mapper.map_manager, prev_id, new_id);
        end
    catch e
        showerror(stdout, e); println()
        display(stacktrace(catch_backtrace())); println()
    finally
        unlock(mapper.map_manager.map_lock)
        unlock(mapper.map_manager.optimization_lock)
    end
end

"""
Given a frame and its local map of Keypoints ids (triangulated),
project respective mappoints onto the frame, find surrounding keypoints (triangulated?),
match surrounding keypoints with the projection.
Best match is the new candidate for replacement.
"""
function do_local_map_matching(
    mapper::Mapper, frame::Frame, local_map::Set{Int64};
    max_projection_distance, max_descriptor_distance,
)
    prev_new_map = Dict{Int64, Int64}()
    isempty(local_map) && return prev_new_map

    # Maximum field of view.
    vfov = 0.5 * frame.camera.height / frame.camera.fy
    hfov = 0.5 * frame.camera.width / frame.camera.fx
    max_rad_fov = vfov > hfov ? atan(vfov) : atan(hfov)
    view_threshold = cos(max_rad_fov)

    # Define max distance from projection.
    frame.nb_3d_kpts < 30 && (max_projection_distance *= 2.0;)
    # matched kpid → [(local map kpid, distance)] TODO
    matches = Dict{Int64, Vector{Tuple{Int64, Float64}}}()

    # Go through all MapPoints from the local map in `frame`.
    for kpid in local_map
        is_observing_kp(frame, kpid) && continue
        mp = get_mappoint(mapper.map_manager, kpid)
        mp ≡ nothing && continue
        (!mp.is_3d || isempty(mp.descriptor)) && continue

        # Project MapPoint into KeyFrame's image plane.
        position = get_position(mp)
        camera_position = project_world_to_camera(frame, position)[1:3]
        camera_position[3] < 0.1 && continue

        view_angle = camera_position[3] / norm(camera_position)
        abs(view_angle) < view_threshold && continue

        projection = project_undistort(frame.camera, camera_position)
        in_image(frame.camera, projection) || continue

        surrounding_keypoints = get_surrounding_keypoints(frame, projection)

        # Find best match for the `mp` among `surrounding_keypoints`.
        best_id, best_distance = find_best_match(
            mapper.map_manager, frame, mp, projection, surrounding_keypoints;
            max_projection_distance, max_descriptor_distance)
        best_id == -1 && continue

        match = (kpid, best_distance)
        if best_id in keys(matches)
            push!(matches[best_id], match)
        else
            matches[best_id] = Tuple{Int64, Float64}[match]
        end
    end

    for (kpid, match) in matches
        best_distance = 1e6
        best_id = -1

        for (local_kpid, distance) in match
            if distance ≤ best_distance
                best_distance = distance
                best_id = local_kpid
            end
            best_id != -1 && (prev_new_map[kpid] = best_id;)
        end
    end
    prev_new_map
end

"""
For a given `target_mp` MapPoint, find best match among surrounding keypoints.

Given target mappoint from covisibility graph, its projection onto `frame`
and surrounding keypoints in `frame` for that projection,
find best matching keypoint (already triangulated?) in `frame`.
"""
function find_best_match(
    map_manager::MapManager, frame::Frame, target_mp::MapPoint,
    projection, surrounding_keypoints;
    max_projection_distance, max_descriptor_distance,
)
    target_mp_observers = get_observers(target_mp)
    target_mp_position = get_position(target_mp)

    # TODO parametrize descriptor size.
    min_distance = 256.0 * max_descriptor_distance
    best_distance, second_distance = min_distance, min_distance
    best_id, second_id = -1, -1

    for kp in surrounding_keypoints
        kp.id < 0 && continue
        distance = norm(projection .- kp.pixel)
        distance > max_projection_distance && continue

        mp = get_mappoint(map_manager, kp.id)
        if mp ≡ nothing
            remove_mappoint_obs!(map_manager, kp.id, frame.kfid)
            continue
        end
        isempty(mp.descriptor) && continue

        # Check that `kp` and `target_mp` are indeed candidates for matching.
        # They should have no overlap in their observers.
        mp_observers = get_observers(mp)
        isempty(intersect(target_mp_observers, mp_observers)) || continue

        avg_projection = 0.0
        n_projections = 0

        # Compute average projection distance for the `target_mp` projected
        # into each of the `mp` observers KeyFrame.
        for observer_kfid in mp_observers
            observer_kf = get_keyframe(map_manager, observer_kfid)
            observer_kf ≡ nothing && (remove_mappoint_obs!(
                map_manager, kp.id, observer_kfid); continue)

            observer_kp = get_keypoint(observer_kf, kp.id)
            observer_kp ≡ nothing && (remove_mappoint_obs!(
                map_manager, kp.id, observer_kfid); continue)

            observer_projection = project_world_to_image_distort(
                observer_kf, target_mp_position)
            avg_projection += norm(observer_kp.pixel .- observer_projection)
            n_projections += 1
        end
        avg_projection /= n_projections
        avg_projection > max_projection_distance && continue

        distance = mappoint_min_distance(target_mp, mp)
        if distance ≤ best_distance
            second_distance = best_distance
            second_id = best_id

            best_distance = distance
            best_id = kp.id
        elseif distance ≤ second_distance
            second_distance = distance
            second_id = kp.id
        end
    end

    # TODO is this necessary?
    # best_id != -1 && second_id != -1 &&
    #     0.9 * second_distance < best_distance && (best_id = -1;)

    best_id, best_distance
end

function get_new_kf!(mapper::Mapper)
    lock(mapper.queue_lock) do
        if isempty(mapper.keyframe_queue)
            mapper.new_kf_available = false
            return false, nothing
        end

        keyframe = popfirst!(mapper.keyframe_queue)
        mapper.new_kf_available = !isempty(mapper.keyframe_queue)
        true, keyframe
    end
end

function add_new_kf!(mapper::Mapper, kf::KeyFrame)
    lock(mapper.queue_lock) do
        push!(mapper.keyframe_queue, kf)
        mapper.new_kf_available = true
    end
end

function reset!(mapper::Mapper)
    lock(mapper.queue_lock) do
        mapper.new_kf_available = false
        mapper.exit_required = false
        mapper.keyframe_queue |> empty!
    end
end
