from __future__ import annotations

from typing import Dict, Tuple

import numpy as np
import torch

from vggt.utils.device import maybe_autocast, sync_device
from vggt.utils.geometry import depth_to_world_coords_points, project_world_points_to_cam
from vggt.utils.helper import randomly_limit_trues


def _supports_rig_frame_api(pycolmap) -> bool:
    reconstruction = pycolmap.Reconstruction()
    return (
        hasattr(reconstruction, "add_rig")
        and hasattr(reconstruction, "add_frame")
        and hasattr(reconstruction, "register_frame")
        and hasattr(pycolmap, "sensor_t")
        and hasattr(pycolmap, "data_t")
        and hasattr(pycolmap, "SensorType")
    )


def _to_point2d_list(pycolmap, points2d):
    if hasattr(pycolmap, "ListPoint2D"):
        return pycolmap.ListPoint2D(points2d)
    return points2d


def _registered_image_ids(reconstruction):
    if hasattr(reconstruction, "reg_image_ids"):
        try:
            ids = [int(image_id) for image_id in reconstruction.reg_image_ids()]
            if ids:
                return ids
        except Exception:  # noqa: BLE001
            pass

    ids = []
    for image_id, image in reconstruction.images.items():
        if getattr(image, "registered", False):
            ids.append(int(image_id))
    return ids


def _build_pycolmap_intri(fidx, intrinsics, camera_type, extra_params=None):
    if camera_type == "PINHOLE":
        pycolmap_intri = np.array(
            [
                intrinsics[fidx][0, 0],
                intrinsics[fidx][1, 1],
                intrinsics[fidx][0, 2],
                intrinsics[fidx][1, 2],
            ]
        )
    elif camera_type == "SIMPLE_PINHOLE":
        focal = (intrinsics[fidx][0, 0] + intrinsics[fidx][1, 1]) / 2
        pycolmap_intri = np.array(
            [focal, intrinsics[fidx][0, 2], intrinsics[fidx][1, 2]]
        )
    else:
        raise ValueError(f"Camera type {camera_type} is not supported yet")
    return pycolmap_intri


def build_track_reconstruction(
    model,
    vgg_input: torch.Tensor,
    image_paths,
    extrinsics: np.ndarray,
    intrinsics: np.ndarray,
    depth_map: np.ndarray,
    depth_conf: np.ndarray,
    device: torch.device,
    dtype: torch.dtype,
    depth_conf_thresh: float,
    query_frame: int,
    max_tracks: int,
    track_conf_thresh: float,
    track_vis_thresh: float,
    track_reproj_thresh: float,
    track_min_obs: int,
    track_iters: int | None,
    camera_type: str = "PINHOLE",
    shared_camera: bool = False,
) -> Tuple["pycolmap.Reconstruction" | None, Dict[str, int]]:
    import pycolmap

    stats: Dict[str, int] = {
        "total_tracks": 0,
        "kept_tracks": 0,
        "total_observations": 0,
    }

    num_frames = extrinsics.shape[0]
    if len(image_paths) != num_frames:
        print(
            f"⚠️  image_paths length ({len(image_paths)}) does not match extrinsics ({num_frames}); using extrinsics length"
        )
    if query_frame < 0 or query_frame >= num_frames:
        raise ValueError(f"query_frame {query_frame} is out of range")

    depth_frame = depth_map[query_frame]
    if depth_frame.ndim == 3:
        depth_frame = depth_frame[..., 0]
    conf_frame = depth_conf[query_frame]
    if conf_frame.ndim == 3:
        conf_frame = conf_frame[..., 0]

    valid_depth = np.isfinite(depth_frame) & (depth_frame > 0)
    conf_mask = conf_frame >= depth_conf_thresh
    mask = valid_depth & conf_mask
    if mask.sum() == 0:
        return None, stats

    if max_tracks is not None and max_tracks > 0:
        mask = randomly_limit_trues(mask, max_tracks)

    ys, xs = np.nonzero(mask)
    if ys.size == 0:
        return None, stats

    query_points = np.stack([xs, ys], axis=1).astype(np.float32)

    world_points, _, _ = depth_to_world_coords_points(
        depth_frame, extrinsics[query_frame], intrinsics[query_frame]
    )
    points3d = world_points[ys, xs]

    img = vgg_input[query_frame].detach().float().cpu().numpy()
    img_hwc = np.transpose(img, (1, 2, 0))
    colors = (img_hwc[ys, xs] * 255.0).clip(0, 255).astype(np.uint8)

    finite_mask = np.isfinite(points3d).all(axis=1)
    if finite_mask.sum() == 0:
        return None, stats

    query_points = query_points[finite_mask]
    points3d = points3d[finite_mask]
    colors = colors[finite_mask]

    stats["total_tracks"] = points3d.shape[0]

    query_points_t = torch.from_numpy(query_points).to(device=device, dtype=dtype)
    vgg_input_t = vgg_input.to(device=device, dtype=dtype)

    with torch.no_grad():
        with maybe_autocast(device, dtype):
            sync_device(device)
            predictions = model(
                vgg_input_t, query_points=query_points_t, track_iters=track_iters
            )
            sync_device(device)

    tracks = predictions["track"][0].detach().float().cpu().numpy()
    vis = predictions["vis"][0].detach().float().cpu().numpy()
    conf_pred = predictions.get("conf")
    if conf_pred is None:
        conf = np.ones_like(vis)
    else:
        conf = conf_pred[0].detach().float().cpu().numpy()

    world_points_t = torch.from_numpy(points3d).float()
    extrinsics_t = torch.from_numpy(extrinsics).float()
    intrinsics_t = torch.from_numpy(intrinsics).float()

    proj_xy, cam_points = project_world_points_to_cam(
        world_points_t, extrinsics_t, intrinsics_t
    )
    proj_xy = proj_xy.detach().cpu().numpy()
    cam_z = cam_points[:, 2, :].detach().cpu().numpy()

    height = vgg_input.shape[2]
    width = vgg_input.shape[3]

    in_bounds = (
        (tracks[..., 0] >= 0)
        & (tracks[..., 0] <= (width - 1))
        & (tracks[..., 1] >= 0)
        & (tracks[..., 1] <= (height - 1))
    )
    reproj_err = np.linalg.norm(tracks - proj_xy, axis=-1)

    valid_obs = (
        (vis >= track_vis_thresh)
        & (conf >= track_conf_thresh)
        & (reproj_err <= track_reproj_thresh)
        & (cam_z > 0)
        & in_bounds
    )

    reconstruction = pycolmap.Reconstruction()
    use_rig_frame_api = _supports_rig_frame_api(pycolmap)
    image_size = np.array([width, height])
    camera_ids = np.zeros(num_frames, dtype=np.int32)

    camera = None
    for fidx in range(num_frames):
        if camera is None or not shared_camera:
            pycolmap_intri = _build_pycolmap_intri(fidx, intrinsics, camera_type)
            camera_id = 1 if shared_camera else (fidx + 1)
            camera = pycolmap.Camera(
                model=camera_type,
                width=image_size[0],
                height=image_size[1],
                params=pycolmap_intri,
                camera_id=camera_id,
            )
            reconstruction.add_camera(camera)
        camera_ids[fidx] = camera.camera_id

    for fidx in range(num_frames):
        image_id = int(fidx + 1)
        camera_id = int(camera_ids[fidx])
        cam_from_world = pycolmap.Rigid3d(
            pycolmap.Rotation3d(extrinsics[fidx][:3, :3]), extrinsics[fidx][:3, 3]
        )

        if use_rig_frame_api:
            sensor_id = pycolmap.sensor_t()
            sensor_id.type = pycolmap.SensorType.CAMERA
            sensor_id.id = camera_id

            rig = pycolmap.Rig()
            rig.rig_id = image_id
            rig.add_ref_sensor(sensor_id)
            reconstruction.add_rig(rig)

            frame = pycolmap.Frame()
            frame.frame_id = image_id
            frame.rig_id = rig.rig_id
            frame.rig = reconstruction.rigs[rig.rig_id]

            data_id = pycolmap.data_t()
            data_id.sensor_id = sensor_id
            data_id.id = image_id
            frame.add_data_id(data_id)
            frame.set_cam_from_world(camera_id, cam_from_world)
            reconstruction.add_frame(frame)

            image = pycolmap.Image(
                name=f"image_{image_id}",
                camera_id=camera_id,
                image_id=image_id,
            )
            image.frame_id = frame.frame_id
            reconstruction.add_image(image)
        else:
            image = pycolmap.Image(
                id=image_id,
                name=f"image_{image_id}",
                camera_id=camera_id,
                cam_from_world=cam_from_world,
            )
            reconstruction.add_image(image)

    points2d_lists = {image_id: [] for image_id in reconstruction.images.keys()}

    kept = 0
    kept_points3d = []
    kept_colors = []
    kept_track_elements = []
    for idx in range(points3d.shape[0]):
        obs_frames = np.nonzero(valid_obs[:, idx])[0]
        if query_frame not in obs_frames:
            continue
        if obs_frames.size < track_min_obs:
            continue

        track_elements = []
        for fidx in obs_frames:
            image_id = int(fidx) + 1
            point2d_idx = len(points2d_lists[image_id])
            xy = tracks[fidx, idx].astype(np.float64)
            points2d_lists[image_id].append(pycolmap.Point2D(xy))
            track_elements.append((image_id, point2d_idx))

        kept_track_elements.append(track_elements)
        kept_points3d.append(points3d[idx])
        kept_colors.append(colors[idx])
        kept += 1
        stats["total_observations"] += obs_frames.size

    stats["kept_tracks"] = kept

    if kept == 0:
        return None, stats

    for image_id, points2d in points2d_lists.items():
        image = reconstruction.images[image_id]
        if len(points2d) > 0:
            image.points2D = _to_point2d_list(pycolmap, points2d)
            if hasattr(image, "registered"):
                image.registered = True
            elif use_rig_frame_api and hasattr(image, "frame_id"):
                reconstruction.register_frame(int(image.frame_id))
        else:
            if hasattr(image, "registered"):
                image.registered = False

    for idx in range(kept):
        track = pycolmap.Track()
        for image_id, point2d_idx in kept_track_elements[idx]:
            track.add_element(image_id, point2d_idx)
        reconstruction.add_point3D(kept_points3d[idx], track, kept_colors[idx])

    return reconstruction, stats


def run_bundle_adjustment(
    reconstruction,
    max_iterations: int,
    refine_focal: bool,
    refine_pp: bool,
    refine_extra: bool,
) -> None:
    import pycolmap

    ba_options = pycolmap.BundleAdjustmentOptions()
    if hasattr(ba_options, "max_num_iterations"):
        ba_options.max_num_iterations = max_iterations
    elif hasattr(ba_options, "solver_options") and hasattr(
        ba_options.solver_options, "max_num_iterations"
    ):
        ba_options.solver_options.max_num_iterations = max_iterations

    if hasattr(ba_options, "refine_focal_length"):
        ba_options.refine_focal_length = refine_focal
    if hasattr(ba_options, "refine_principal_point"):
        ba_options.refine_principal_point = refine_pp
    if hasattr(ba_options, "refine_extra_params"):
        ba_options.refine_extra_params = refine_extra

    registered_ids = _registered_image_ids(reconstruction)
    if len(registered_ids) == 0:
        print("⚠️  No registered images for BA; skipping")
        return

    ba_config = None
    if hasattr(pycolmap, "BundleAdjustmentConfig"):
        ba_config = pycolmap.BundleAdjustmentConfig()
        for image_id in registered_ids:
            ba_config.add_image(int(image_id))

    if hasattr(reconstruction, "bundle_adjustment"):
        try:
            if ba_config is not None:
                reconstruction.bundle_adjustment(ba_config, ba_options)
            else:
                reconstruction.bundle_adjustment(ba_options)
            return
        except Exception:  # noqa: BLE001
            pass

    try:
        pycolmap.bundle_adjustment(reconstruction, ba_options)
    except TypeError:
        if ba_config is None:
            raise
        pycolmap.bundle_adjustment(reconstruction, ba_config, ba_options)
