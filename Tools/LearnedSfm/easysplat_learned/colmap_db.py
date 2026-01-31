import sqlite3
from typing import Dict, Iterable, List, Tuple

import numpy as np

MAX_IMAGE_ID = 2**31 - 1


def image_ids_to_pair_id(image_id1: int, image_id2: int) -> int:
    if image_id1 > image_id2:
        image_id1, image_id2 = image_id2, image_id1
    return image_id1 * MAX_IMAGE_ID + image_id2


def _blob(array: np.ndarray) -> bytes:
    if array.size == 0:
        return b""
    return array.tobytes()


def create_schema(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS cameras (
            camera_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            model INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            params BLOB NOT NULL,
            prior_focal_length INTEGER NOT NULL
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS images (
            image_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            name TEXT NOT NULL UNIQUE,
            camera_id INTEGER NOT NULL,
            prior_qw REAL,
            prior_qx REAL,
            prior_qy REAL,
            prior_qz REAL,
            prior_tx REAL,
            prior_ty REAL,
            prior_tz REAL
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS keypoints (
            image_id INTEGER PRIMARY KEY NOT NULL,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS descriptors (
            image_id INTEGER PRIMARY KEY NOT NULL,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS matches (
            pair_id INTEGER PRIMARY KEY NOT NULL,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS two_view_geometries (
            pair_id INTEGER PRIMARY KEY NOT NULL,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB,
            config INTEGER NOT NULL,
            F BLOB,
            E BLOB,
            H BLOB
        );
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS image_name_index ON images(name);")


def insert_camera(
    conn: sqlite3.Connection,
    model_id: int,
    width: int,
    height: int,
    params: Iterable[float],
    prior_focal_length: int = 1,
) -> int:
    params_arr = np.array(list(params), dtype=np.float64)
    cursor = conn.execute(
        "INSERT INTO cameras(model, width, height, params, prior_focal_length) VALUES (?, ?, ?, ?, ?)",
        (model_id, width, height, _blob(params_arr), prior_focal_length),
    )
    return int(cursor.lastrowid)


def insert_image(conn: sqlite3.Connection, name: str, camera_id: int) -> int:
    cursor = conn.execute(
        "INSERT INTO images(name, camera_id, prior_qw, prior_qx, prior_qy, prior_qz, prior_tx, prior_ty, prior_tz) "
        "VALUES (?, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL)",
        (name, camera_id),
    )
    return int(cursor.lastrowid)


def insert_keypoints(conn: sqlite3.Connection, image_id: int, keypoints: np.ndarray) -> None:
    rows = int(keypoints.shape[0])
    cols = int(keypoints.shape[1]) if keypoints.ndim == 2 else 2
    payload = keypoints.astype(np.float32, copy=False)
    conn.execute(
        "INSERT INTO keypoints(image_id, rows, cols, data) VALUES (?, ?, ?, ?)",
        (image_id, rows, cols, _blob(payload)),
    )


def insert_descriptors(conn: sqlite3.Connection, image_id: int, count: int) -> None:
    rows = int(count)
    cols = 128
    if rows == 0:
        payload = np.empty((0, cols), dtype=np.uint8)
    else:
        payload = np.zeros((rows, cols), dtype=np.uint8)
    conn.execute(
        "INSERT INTO descriptors(image_id, rows, cols, data) VALUES (?, ?, ?, ?)",
        (image_id, rows, cols, _blob(payload)),
    )


def insert_matches(
    conn: sqlite3.Connection,
    image_id1: int,
    image_id2: int,
    matches: np.ndarray,
) -> None:
    if matches.size == 0:
        return
    if image_id1 > image_id2:
        matches = matches[:, ::-1]
    pair_id = image_ids_to_pair_id(image_id1, image_id2)
    rows = int(matches.shape[0])
    cols = int(matches.shape[1])
    payload = matches.astype(np.uint32, copy=False)
    conn.execute(
        "INSERT OR REPLACE INTO matches(pair_id, rows, cols, data) VALUES (?, ?, ?, ?)",
        (pair_id, rows, cols, _blob(payload)),
    )


def write_database(
    db_path: str,
    images: List[str],
    image_sizes: Dict[str, Tuple[int, int]],
    camera_model: str,
    keypoints: Dict[str, np.ndarray],
    matches: Dict[Tuple[str, str], np.ndarray],
) -> None:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute("PRAGMA journal_mode=MEMORY")
    create_schema(conn)

    camera_map: Dict[Tuple[int, int], int] = {}
    image_id_map: Dict[str, int] = {}

    for name in images:
        width, height = image_sizes[name]
        cam_key = (width, height)
        if cam_key not in camera_map:
            model_id, params = camera_params(camera_model, width, height)
            camera_map[cam_key] = insert_camera(conn, model_id, width, height, params)
        camera_id = camera_map[cam_key]
        image_id_map[name] = insert_image(conn, name, camera_id)

    for name in images:
        kp = keypoints.get(name)
        if kp is None:
            kp = np.empty((0, 2), dtype=np.float32)
        insert_keypoints(conn, image_id_map[name], kp)
        insert_descriptors(conn, image_id_map[name], kp.shape[0])

    for (name1, name2), match_arr in matches.items():
        id1 = image_id_map[name1]
        id2 = image_id_map[name2]
        insert_matches(conn, id1, id2, match_arr)

    conn.commit()
    conn.close()


def camera_params(model_name: str, width: int, height: int) -> Tuple[int, List[float]]:
    model_name = model_name.upper()
    max_dim = float(max(width, height))
    focal = 1.2 * max_dim
    cx = width / 2.0
    cy = height / 2.0

    model_map = {
        "SIMPLE_PINHOLE": (0, [focal, cx, cy]),
        "PINHOLE": (1, [focal, focal, cx, cy]),
        "SIMPLE_RADIAL": (2, [focal, cx, cy, 0.0]),
        "RADIAL": (3, [focal, cx, cy, 0.0, 0.0]),
        "OPENCV": (4, [focal, focal, cx, cy, 0.0, 0.0, 0.0, 0.0]),
        "FULL_OPENCV": (6, [focal, focal, cx, cy, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
    }
    if model_name not in model_map:
        model_name = "SIMPLE_RADIAL"
    return model_map[model_name]
