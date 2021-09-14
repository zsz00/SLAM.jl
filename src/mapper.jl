struct KeyFrame
    id::Int64
    image::Matrix{Gray}
end

mutable struct Mapper
    params::Params
    map_manager::MapManager
    estimator::Estimator

    current_frame::Frame
    keyframe_queue::Vector{KeyFrame}

    exit_required::Bool
    new_kf_available::Bool

    estimator_thread
    queue_lock::ReentrantLock
end

function Mapper(params::Params, map_manager::MapManager, frame::Frame)
    estimator = Estimator(map_manager, params)
    estimator_thread = @spawn run!(estimator)
    @debug "[MP] Launched estimator."

    Mapper(
        params, map_manager, estimator,
        frame, KeyFrame[], false, false,
        estimator_thread, ReentrantLock(),
    )
end

function run!(mapper::Mapper)
    while !mapper.exit_required
        succ, kf = get_new_kf!(mapper)
        if !succ
            # @debug "[MP] No new Keyframe to process."
            sleep(1)
            continue
        end

        @debug "[MP] New keyframe to process: $(kf.id) id."
        new_keyframe = get_keyframe(mapper.map_manager, kf.id)

        if new_keyframe.nb_2d_kpts > 0 && new_keyframe.kfid > 0
            @debug "[MP] Temporal triangulation. Before triangulation:"
            @debug "\t 2d $(new_keyframe.nb_2d_kpts), " *
                "3d $(new_keyframe.nb_3d_kpts), " *
                "3d total $(mapper.current_frame.nb_3d_kpts)"

            lock(mapper.map_manager.map_lock) do
                triangulate_temporal!(mapper, new_keyframe)
            end

            @debug "[MP] After triangulation:"
            @debug "\t 2d $(new_keyframe.nb_2d_kpts), " *
                "3d $(new_keyframe.nb_3d_kpts), " *
                "3d total $(mapper.current_frame.nb_3d_kpts)"
        end

        # Check if reset is required.
        if mapper.params.vision_initialized
            if kf.id == 1 && new_keyframe.nb_3d_kpts < 30
                @debug "[MP] Bad initialization detected. Resetting!"
                mapper.params.reset_required = true
                mapper |> reset!
                continue
            elseif kf.id < 10 && new_keyframe.nb_3d_kpts < 3
                @debug "[MP] Reset required. Nb 3D points: $(new_keyframe.nb_3d_kpts)."
                mapper.params.reset_required = true
                mapper |> reset!
                continue
            end
        end
        # Update the map points and the covisibility graph between KeyFrames.
        update_frame_covisibility!(mapper.map_manager, new_keyframe)

        # TODO match to local map
        # Send new KF to estimator for bundle adjustment.
        @debug "[MP] Sending new Keyframe to Estimator."
        add_new_kf!(mapper.estimator, new_keyframe)
        # TODO send new KF to loop closer
    end
    mapper.estimator.exit_required = true
    @debug "[MP] Exit required."
    wait(mapper.estimator_thread)
end

function triangulate_temporal!(mapper::Mapper, frame::Frame)
    keypoints = get_2d_keypoints(frame)
    if isempty(keypoints)
        @debug "[MP] No 2D keypoints to triangulate."
        return
    end
    K = to_4x4(frame.camera.K)
    P1 = K * SMatrix{4, 4, Float64}(I)

    good = 0
    candidates = 0
    rel_kfid = -1
    # frame -> observer key frame.
    rel_pose = SMatrix{4, 4, Float64}(I)
    # observer key frame -> frame.
    rel_pose_inv = SMatrix{4, 4, Float64}(I)

    max_error = mapper.params.max_reprojection_error
    cam = frame.camera

    # Go through all 2D keypoints in `frame`.
    for kp in keypoints
        # Remove mappoints observation if not in map.
        if !(kp.id in keys(mapper.map_manager.map_points))
            remove_mappoint_obs!(mapper.map_manager, kp.id, frame.kfid)
            @debug "[MP] No MapPoint for KP" maxlog=10
            continue
        end
        map_point = mapper.map_manager.map_points[kp.id]
        if map_point.is_3d
            @debug "[MP] Already 3d" maxlog=10
            continue
        end
        # Get first KeyFrame id from the set of mappoint observers.
        if length(map_point.observer_keyframes_ids) < 2
            @debug "[MP] Not enough observers @ $(frame.kfid): $(map_point.observer_keyframes_ids)" maxlog=10
            continue
        end
        kfid = map_point.observer_keyframes_ids[1]
        if frame.kfid == kfid
            @debug "[MP] Observer is the same as Frame" maxlog=10
            continue
        end
        # Get 1st KeyFrame observation for the MapPoint.
        observer_kf = mapper.map_manager.frames_map[kfid]
        # Compute relative motion between new KF & observer KF.
        # Don't recompute if the frame's ids don't change.
        if rel_kfid != kfid
            rel_pose = observer_kf.cw * frame.wc
            rel_pose_inv = inv(SE3, rel_pose)
            rel_kfid = kfid
        end
        # Get observer keypoint.
        if !(kp.id in keys(observer_kf.keypoints))
            @debug "[MP] Observer has no such KP" maxlog=10
            continue
        end
        observer_kp = observer_kf.keypoints[kp.id]

        obup = observer_kp.undistorted_pixel
        kpup = kp.undistorted_pixel

        parallax = norm(obup .- project(cam, rel_pose[1:3, 1:3] * kp.position))
        candidates += 1
        # Compute 3D pose and check if it is good.
        # Note, that we use inverted relative pose.
        left_point = iterative_triangulation(
            observer_kp.undistorted_pixel[[2, 1]], kp.undistorted_pixel[[2, 1]],
            P1, K * rel_pose_inv,
        )
        left_point *= 1.0 / left_point[4]
        # Project into the right camera (new KeyFrame).
        right_point = rel_pose_inv * left_point

        # Ensure that 3D point is in front of the both cameras.
        if left_point[3] < 0 || right_point[3] < 0
            parallax > 20 && remove_mappoint_obs!(
                mapper.map_manager, observer_kp.id, frame.kfid,
            )
            @debug "[MP] Triangulation is behind cameras." maxlog=10
            continue
        end
        # Remove MapPoint with high reprojection error.
        lrepr = norm(project(cam, left_point[1:3]) .- obup)
        rrepr = norm(project(cam, right_point[1:3]) .- kpup)
        if lrepr > max_error || rrepr > max_error
            parallax > 20 && remove_mappoint_obs!(
                mapper.map_manager, observer_kp.id, frame.kfid,
            )
            @debug "[MP] Triangulation has too big repr error $lrepr, $rrepr" maxlog=10
            continue
        end
        # 3D pose is good, update MapPoint and related Frames.
        wpt = project_camera_to_world(observer_kf, left_point)[1:3]
        update_mappoint!(mapper.map_manager, kp.id, wpt)
        good += 1
    end
    @debug "[MP] Temporal triangulation: $good/$candidates good KeyPoints."
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
