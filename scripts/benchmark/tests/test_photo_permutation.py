from __future__ import annotations

import copy
import hashlib
import itertools
import json
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator

from scripts.benchmark import evidence_protocol as evidence


ROOT = Path(__file__).resolve().parents[3]


def digest(label: str) -> str:
    return "sha256:" + hashlib.sha256(label.encode("utf-8")).hexdigest()


def opaque_digest(label: str) -> str:
    return "opaque-sha256:" + hashlib.sha256(label.encode("utf-8")).hexdigest()


def content_set_digest(ids: list[str]) -> str:
    payload = evidence.canonical_json_bytes(ids)
    return "opaque-sha256:" + hashlib.sha256(
        b"easysplat-photo-content-set-v1\0" + payload
    ).hexdigest()


def pair_edge(first: str, second: str) -> dict[str, str]:
    content_a, content_b = sorted((first, second))
    payload = evidence.canonical_json_bytes([content_a, content_b])
    return {
        "content_a": content_a,
        "content_b": content_b,
        "edge_id": "opaque-sha256:"
        + hashlib.sha256(b"easysplat-photo-pair-edge-v1\0" + payload).hexdigest(),
    }


def pair_edges(content_ids: list[str], count: int, *, skip: int = 0) -> list[dict[str, str]]:
    pairs = itertools.islice(itertools.combinations(content_ids, 2), skip, skip + count)
    return sorted((pair_edge(first, second) for first, second in pairs), key=lambda edge: edge["edge_id"])


def pair_graph_digest(edges: list[dict[str, str]]) -> str:
    edge_ids = [edge["edge_id"] for edge in edges]
    payload = json.dumps(
        edge_ids,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return "opaque-sha256:" + hashlib.sha256(
        b"easysplat-photo-pair-graph-v1\0" + payload
    ).hexdigest()


def request(scale: int = 61, *, category: str = "professional_photos") -> dict[str, object]:
    plan = {
        "capture_path": "automatic",
        "input_topology": "unordered",
        "pairing_policy": (
            "unordered_exhaustive" if scale <= 60 else "unordered_retrieval"
        ),
        "photo_selection": "automatic",
        "run_seed": 42,
        "selected_frame_count": scale,
    }
    return {
        "binding": {"scale": scale},
        "candidate_run_configuration": plan,
        "category": category,
        "input_kind": "photos",
    }


def variant(
    index: int | None,
    *,
    scale: int = 61,
    source_kind: str = "native_photos",
    edges: list[dict[str, str]] | None = None,
    release_seed: bool = True,
) -> dict[str, object]:
    is_canonical = index is None
    selected_ids = sorted(opaque_digest(f"content-{position}") for position in range(scale))
    plan = request(scale)["candidate_run_configuration"]
    assert isinstance(plan, dict)
    retrieval = scale > 60
    scheduled_count = scale if retrieval else scale * (scale - 1) // 2
    normalized_edges = edges or pair_edges(selected_ids, scheduled_count)
    return {
        "group_id": "unordered-group-01",
        "variant_id": "canonical" if is_canonical else f"shuffle-{index:02d}",
        "permutation": (
            {"kind": "canonical"}
            if is_canonical
            else {
                "kind": "shuffled",
                "index": index,
                "seed": (
                    evidence.photo_permutation_release_seed(index)
                    if release_seed
                    else 1000 + index
                ),
            }
        ),
        "order_commitment": opaque_digest(
            "canonical-order" if is_canonical else f"shuffle-order-{index}"
        ),
        "content_set_attestation": opaque_digest("content-set-attestation"),
        "canonical_observation_attestation": opaque_digest(
            "canonical-observation"
        ),
        "source_kind": source_kind,
        "selected_content_ids": selected_ids,
        "registered_content_ids": selected_ids,
        "selected_content_set_sha256": content_set_digest(selected_ids),
        "registered_content_set_sha256": content_set_digest(selected_ids),
        "normalized_pair_graph_sha256": pair_graph_digest(normalized_edges),
        "normalized_pair_edges": normalized_edges,
        "requested_plan_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(plan)
        ),
        "scale": scale,
        "run_seed": 42,
        "pairing_policy": (
            "unordered_retrieval" if retrieval else "unordered_exhaustive"
        ),
        "accepted_attempt": (
            "vocabulary_retrieval" if retrieval else "exhaustive_primary"
        ),
        "scheduled_pair_count": scheduled_count,
        "scheduled_pair_graph_sha256": pair_graph_digest(normalized_edges),
        "attempted_pair_count": scheduled_count,
        "attempted_pair_graph_sha256": pair_graph_digest(normalized_edges),
        "raw_matched_pair_count": scheduled_count,
        "raw_matched_pair_graph_sha256": pair_graph_digest(normalized_edges),
        "spatially_verified_pair_count": len(normalized_edges),
        "retrieval_worker_executed": retrieval,
        "pair_counts": {
            "temporal": 0,
            "vocabulary_retrieval": scheduled_count if retrieval else 0,
            "loop_revisit": 0,
            "exhaustive_primary": 0 if retrieval else scheduled_count,
            "exhaustive_recovery": 0,
        },
        "registered_views": scale,
        "point_count": scale * 100,
        "observation_count": scale * 400,
        "residual_median_pixels": 0.50,
        "residual_p90_pixels": 1.00,
        "camera_center_p95_scene_radius_fraction": 0.0 if is_canonical else 0.005,
        "rotation_p95_degrees": 0.0 if is_canonical else 0.10,
    }


def group(
    *,
    count: int = 20,
    mode: str = "release",
    scale: int = 61,
    source_kind: str = "native_photos",
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "mode": mode,
        "expected_variant_count": count,
        "closure_claims": ["order_mechanics", "professional_photo"],
        "variants": [
            variant(None, scale=scale, source_kind=source_kind),
            *[
                variant(index, scale=scale, source_kind=source_kind)
                for index in range(1, count)
            ],
        ],
    }


def seal_group(
    value: dict[str, object],
    request_value: dict[str, object] | None = None,
) -> dict[str, object]:
    value.pop("execution_provenance", None)
    variants = value["variants"]
    assert isinstance(variants, list)
    schedule = [
        {
            "variant_id": item["variant_id"],
            "permutation": item["permutation"],
        }
        for item in variants
    ]
    slot_receipts = [
        {
            "variant_id": item["variant_id"],
            "public_variant_sha256": evidence.sha256_bytes(
                evidence.canonical_json_bytes(item)
            ),
            "receipt_sha256": digest(f"slot-{item['variant_id']}"),
        }
        for item in variants
    ]
    protected_request = request_value or request(int(variants[0]["scale"]))
    source_authorization = {
        "schema_version": 1,
        "kind": "easysplat-photo-permutation-source-authorization",
        "request_binding_sha256": evidence.photo_permutation_request_binding_sha256(
            protected_request
        ),
        "source_kind": variants[0]["source_kind"],
        "source_manifest_sha256": digest("source-manifest"),
        "source_content_set_sha256": digest("source-content-set"),
        "origin_evidence_sha256": digest("origin-evidence"),
        "adapter_sha256": digest("adapter"),
        "toolchain_closure_sha256": digest("toolchain"),
        "containment_supervisor_sha256": digest("containment-supervisor"),
        "containment_policy_sha256": digest("containment-policy"),
        "dedicated_uid": 520,
        "gh_verifier_sha256": digest("gh-verifier"),
        "source_commit": protected_request.get("binding", {}).get(
            "git_commit", "1" * 40
        ),
        "source_ref": "refs/heads/main",
    }
    receipt = {
        "schema_version": 1,
        "kind": "easysplat-photo-permutation-execution-receipt",
        "group_contract_sha256": digest("group-contract"),
        "request_binding_sha256": evidence.photo_permutation_request_binding_sha256(
            protected_request
        ),
        "source_authorization_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(source_authorization) + b"\n"
        ),
        "source_kind": variants[0]["source_kind"],
        "trust_boundary": "requires_github_artifact_attestation",
        "source_provenance_commitment": opaque_digest("source-provenance"),
        "producer_implementation_sha256": (
            evidence.photo_permutation_producer_implementation_sha256()
        ),
        "adapter_sha256": digest("adapter"),
        "toolchain_closure_sha256": digest("toolchain"),
        "variant_schedule_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(schedule)
        ),
        "variant_receipts": slot_receipts,
        "variant_receipts_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(slot_receipts)
        ),
        "group_payload_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(value)
        ),
    }
    value["execution_provenance"] = {
        "schema_version": 1,
        "group_contract_sha256": receipt["group_contract_sha256"],
        "request_binding_sha256": receipt["request_binding_sha256"],
        "source_authorization_sha256": receipt[
            "source_authorization_sha256"
        ],
        "source_kind": receipt["source_kind"],
        "trust_boundary": receipt["trust_boundary"],
        "source_provenance_commitment": receipt[
            "source_provenance_commitment"
        ],
        "producer_implementation_sha256": receipt[
            "producer_implementation_sha256"
        ],
        "adapter_sha256": receipt["adapter_sha256"],
        "toolchain_closure_sha256": receipt["toolchain_closure_sha256"],
        "variant_schedule_sha256": receipt["variant_schedule_sha256"],
        "variant_receipts_sha256": receipt["variant_receipts_sha256"],
        "execution_receipt_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(receipt) + b"\n"
        ),
    }
    return receipt


def source_authorization_for(
    request_value: dict[str, object],
    execution_receipt: dict[str, object],
) -> dict[str, object]:
    source_authorization = {
        "schema_version": 1,
        "kind": "easysplat-photo-permutation-source-authorization",
        "request_binding_sha256": evidence.photo_permutation_request_binding_sha256(
            request_value
        ),
        "source_kind": execution_receipt["source_kind"],
        "source_manifest_sha256": digest("source-manifest"),
        "source_content_set_sha256": digest("source-content-set"),
        "origin_evidence_sha256": digest("origin-evidence"),
        "adapter_sha256": execution_receipt["adapter_sha256"],
        "toolchain_closure_sha256": execution_receipt[
            "toolchain_closure_sha256"
        ],
        "containment_supervisor_sha256": digest("containment-supervisor"),
        "containment_policy_sha256": digest("containment-policy"),
        "dedicated_uid": 520,
        "gh_verifier_sha256": digest("gh-verifier"),
        "source_commit": request_value["binding"]["git_commit"],
        "source_ref": "refs/heads/main",
    }
    assert execution_receipt["source_authorization_sha256"] == evidence.sha256_bytes(
        evidence.canonical_json_bytes(source_authorization) + b"\n"
    )
    return source_authorization


def release_coverage_attestation(
    scale: int,
    *,
    source_kind: str = "native_photos",
    category: str = "professional_photos",
) -> dict[str, object]:
    request_value = request(scale, category=category)
    request_value["binding"] = {
        **request_value["binding"],
        "git_commit": "1" * 40,
        "lane": "reference_m4_max",
        "profile": "release",
    }
    request_value["capture_traits"] = ["unordered"]
    request_value["expected_outcome"] = {"kind": "valid"}
    request_value["lane"] = "reference_m4_max"
    value = group(scale=scale, source_kind=source_kind)
    if source_kind != "native_photos":
        value["closure_claims"] = ["order_mechanics"]
    execution_receipt = seal_group(value, request_value)
    source_authorization = source_authorization_for(
        request_value,
        execution_receipt,
    )
    supervisor_provenance = {
        "schema_version": 1,
        "status": "verified",
        "repository": evidence.PHOTO_PERMUTATION_ATTESTATION_REPOSITORY,
        "signer_workflow": evidence.PHOTO_PERMUTATION_ATTESTATION_WORKFLOW,
        "source_commit": "1" * 40,
        "source_ref": "refs/heads/main",
        "subject_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(execution_receipt) + b"\n"
        ),
        "bundle_sha256": digest("attestation-bundle"),
        "verified_attestation_count": 1,
        "source_authorization_subject_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(source_authorization) + b"\n"
        ),
        "source_authorization_bundle_sha256": digest(
            "source-authorization-attestation-bundle"
        ),
        "verified_source_authorization_attestation_count": 1,
    }
    return {
        **request_value,
        "photo_permutation": value,
        "photo_permutation_execution_receipt": execution_receipt,
        "photo_permutation_source_authorization": source_authorization,
        "photo_permutation_supervisor_provenance": supervisor_provenance,
    }


class PhotoPermutationEvidenceTests(unittest.TestCase):
    def validate(self, value: dict[str, object], *, scale: int = 61) -> dict[str, object]:
        self.assertTrue(
            hasattr(evidence, "validate_photo_permutation_group"),
            "photo permutation group validation is not implemented",
        )
        receipt = seal_group(value)
        return evidence.validate_photo_permutation_group(
            value,
            request(scale),
            formal_release=value["mode"] == "release",
            execution_receipt=receipt,
        )

    def test_formal_group_accepts_one_canonical_and_nineteen_shuffles(self) -> None:
        summary = self.validate(group())

        self.assertEqual(summary["variant_count"], 20)
        self.assertGreaterEqual(summary["minimum_pair_graph_jaccard"], 0.98)
        self.assertEqual(summary["maximum_registered_view_loss"], 0)

    def test_rejects_a_consistently_disconnected_accepted_pair_graph(self) -> None:
        value = group(count=6, mode="development")
        variants = value["variants"]
        assert isinstance(variants, list)
        selected_ids = variants[0]["selected_content_ids"]
        assert isinstance(selected_ids, list)
        first_component = selected_ids[:30]
        second_component = selected_ids[30:]
        disconnected_edges = sorted(
            [
                *pair_edges(first_component, 30),
                *pair_edges(second_component, 31),
            ],
            key=lambda edge: edge["edge_id"],
        )
        self.assertEqual(len(disconnected_edges), 61)
        disconnected_digest = pair_graph_digest(disconnected_edges)
        for record in variants:
            record["normalized_pair_edges"] = copy.deepcopy(disconnected_edges)
            record["normalized_pair_graph_sha256"] = disconnected_digest
            record["scheduled_pair_graph_sha256"] = disconnected_digest
            record["attempted_pair_graph_sha256"] = disconnected_digest
            record["raw_matched_pair_graph_sha256"] = disconnected_digest

        with self.assertRaisesRegex(evidence.EvidenceError, "connected"):
            self.validate(value)

    def test_structural_group_without_execution_receipt_is_rejected(self) -> None:
        value = group()
        seal_group(value)
        with self.assertRaisesRegex(
            evidence.EvidenceError, "execution receipt is required"
        ):
            evidence.validate_photo_permutation_group(
                value,
                request(),
                formal_release=True,
            )

    def test_execution_receipt_cannot_replay_across_requests(self) -> None:
        value = group()
        receipt = seal_group(value)
        different_request = request()
        different_request["binding"] = {
            **different_request["binding"],
            "input_digest": digest("different-input"),
            "scene_id": "different-scene",
        }

        with self.assertRaisesRegex(evidence.EvidenceError, "request binding"):
            evidence.validate_photo_permutation_group(
                value,
                different_request,
                formal_release=True,
                execution_receipt=receipt,
            )

    def test_execution_receipt_binds_every_protected_request_field(self) -> None:
        material_fields = {
            "schema_version": (10, 9),
            "baseline_run_configuration": ({"matcher": "exact"}, {"matcher": "faiss"}),
            "holdout_indices": ([4, 9], [3, 8]),
            "reference_artifacts": ({"geometry": digest("a")}, {"geometry": digest("b")}),
            "timing_basis": ("selected_view_count", "wall_clock"),
            "gate_scopes": (["scene_quality"], ["scene_performance"]),
            "rendering_driver_identity": ({"sha256": digest("a")}, {"sha256": digest("b")}),
        }
        for field, (original, changed) in material_fields.items():
            with self.subTest(field=field):
                original_request = request()
                original_request[field] = original
                value = group()
                receipt = seal_group(value, original_request)
                changed_request = copy.deepcopy(original_request)
                changed_request[field] = changed
                with self.assertRaisesRegex(evidence.EvidenceError, "request binding"):
                    evidence.validate_photo_permutation_group(
                        value,
                        changed_request,
                        formal_release=True,
                        execution_receipt=receipt,
                    )

    def test_self_fabricated_producer_identity_is_rejected(self) -> None:
        value = group()
        receipt = seal_group(value)
        forged_digest = digest("fabricated-producer")
        receipt["producer_implementation_sha256"] = forged_digest
        provenance = value["execution_provenance"]
        provenance["producer_implementation_sha256"] = forged_digest
        provenance["execution_receipt_sha256"] = evidence.sha256_bytes(
            evidence.canonical_json_bytes(receipt) + b"\n"
        )

        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "producer implementation does not match this checkout",
        ):
            evidence.validate_photo_permutation_group(
                value,
                request(),
                formal_release=True,
                execution_receipt=receipt,
            )

    def test_execution_receipt_closes_every_variant_slot_to_its_public_payload(self) -> None:
        value = group()
        receipt = seal_group(value)
        receipt["variant_receipts"][4]["public_variant_sha256"] = digest("forged")
        receipt["variant_receipts_sha256"] = evidence.sha256_bytes(
            evidence.canonical_json_bytes(receipt["variant_receipts"])
        )
        provenance = value["execution_provenance"]
        provenance["variant_receipts_sha256"] = receipt["variant_receipts_sha256"]
        provenance["execution_receipt_sha256"] = evidence.sha256_bytes(
            evidence.canonical_json_bytes(receipt) + b"\n"
        )

        with self.assertRaisesRegex(evidence.EvidenceError, "variant receipt"):
            evidence.validate_photo_permutation_group(
                value,
                request(),
                formal_release=True,
                execution_receipt=receipt,
            )

    def test_consistently_bad_geometry_cannot_pass_as_filename_invariant(self) -> None:
        value = group(scale=61)
        variants = value["variants"]
        assert isinstance(variants, list)
        for item in variants:
            registered = item["registered_content_ids"][:3]
            item["registered_content_ids"] = registered
            item["registered_content_set_sha256"] = content_set_digest(registered)
            item["registered_views"] = 3
            item["residual_median_pixels"] = 100.0
            item["residual_p90_pixels"] = 200.0

        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "absolute registration coverage|median residual|p90 residual",
        ):
            self.validate(value)

    def test_empty_sparse_geometry_cannot_pass_as_filename_invariant(self) -> None:
        for field in ("point_count", "observation_count"):
            with self.subTest(field=field):
                value = group()
                variants = value["variants"]
                assert isinstance(variants, list)
                variants[3][field] = 0
                with self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "sparse geometry counts",
                ):
                    self.validate(value)

    def test_sparse_geometry_counts_must_remain_within_one_percent(self) -> None:
        for field in ("point_count", "observation_count"):
            with self.subTest(field=field):
                value = group(scale=120)
                variants = value["variants"]
                assert isinstance(variants, list)
                variants[4][field] = round(variants[0][field] * 1.011)
                with self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "photo permutation .* count delta exceeds 1 percent",
                ):
                    self.validate(value, scale=120)

    def test_scheduled_pairs_must_have_an_exact_attempted_execution_closure(self) -> None:
        value = group(scale=30)
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[4]["attempted_pair_count"] = 1
        variants[4]["attempted_pair_graph_sha256"] = opaque_digest("one-attempt")

        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "attempted pair closure",
        ):
            self.validate(value, scale=30)

    def test_rejects_duplicate_variant_identity(self) -> None:
        value = group()
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[2]["variant_id"] = variants[1]["variant_id"]

        with self.assertRaisesRegex(evidence.EvidenceError, "variant IDs must be unique"):
            self.validate(value)

    def test_rejects_mismatched_content_set_attestation(self) -> None:
        value = group()
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[4]["content_set_attestation"] = opaque_digest("different-content")

        with self.assertRaisesRegex(evidence.EvidenceError, "content-set attestation"):
            self.validate(value)

    def test_formal_group_uses_fixed_public_indices_seeds_and_order(self) -> None:
        self.assertEqual(
            evidence.PHOTO_PERMUTATION_FORMAL_SEEDS,
            (
                4_831_724_571_275_814_301,
                299_878_011_999_028_456,
                2_844_834_447_830_983_243,
                6_231_082_215_795_779_454,
                4_800_438_096_911_084_048,
                2_716_919_709_073_054,
                6_182_739_618_928_064_372,
                1_890_503_712_009_985_873,
                1_568_370_770_626_313_518,
                5_229_953_635_493_634_764,
                2_975_060_197_054_291_650,
                8_734_660_529_696_552_112,
                5_732_113_024_416_928_989,
                7_080_989_793_255_452_606,
                3_391_660_995_046_289_640,
                1_455_629_253_019_862_542,
                4_421_409_204_413_149_686,
                1_852_296_383_023_932_283,
                5_338_892_799_857_249_680,
            ),
        )
        mutations = []
        missing = group()
        missing["variants"].pop(7)
        missing["variants"].append(variant(20, release_seed=False))
        mutations.append(missing)

        substituted = group()
        substituted["variants"][5]["permutation"]["index"] = 19
        mutations.append(substituted)

        reordered = group()
        reordered["variants"][4], reordered["variants"][5] = (
            reordered["variants"][5],
            reordered["variants"][4],
        )
        mutations.append(reordered)

        wrong_seed = group()
        wrong_seed["variants"][8]["permutation"]["seed"] += 1
        mutations.append(wrong_seed)

        seed_from_other_index = group()
        seed_from_other_index["variants"][8]["permutation"]["seed"] = (
            evidence.photo_permutation_release_seed(9)
        )
        mutations.append(seed_from_other_index)

        for candidate in mutations:
            with self.subTest(permutations=[v["permutation"] for v in candidate["variants"]]):
                with self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "fixed canonical and shuffled index/seed schedule",
                ):
                    self.validate(candidate)

    def test_rejects_public_source_paths_hash_maps_and_private_names(self) -> None:
        for leaked_field, leaked_value in (
            ("source_path", "/Users/private/house/IMG_0001.CR3"),
            ("source_sha256", digest("raw-source-image")),
            ("name_to_source", {"IMG_0001.CR3": digest("raw-source-image")}),
        ):
            with self.subTest(leaked_field=leaked_field):
                value = group()
                variants = value["variants"]
                assert isinstance(variants, list)
                variants[0][leaked_field] = leaked_value
                with self.assertRaisesRegex(evidence.EvidenceError, "invalid fields"):
                    self.validate(value)

        value = group()
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[0]["variant_id"] = "/Users/private/IMG_0001.CR3"
        with self.assertRaisesRegex(evidence.EvidenceError, "lowercase token"):
            self.validate(value)

    def test_enforces_sixty_view_exhaustive_boundary(self) -> None:
        value = group(scale=60)
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[3]["pairing_policy"] = "unordered_retrieval"
        variants[3]["accepted_attempt"] = "vocabulary_retrieval"

        with self.assertRaisesRegex(evidence.EvidenceError, "60 or fewer"):
            self.validate(value, scale=60)

    def test_enforces_sixty_one_view_retrieval_boundary(self) -> None:
        value = group(scale=61)
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[3]["pairing_policy"] = "unordered_exhaustive"
        variants[3]["accepted_attempt"] = "exhaustive_primary"
        variants[3]["pair_counts"]["vocabulary_retrieval"] = 0
        variants[3]["pair_counts"]["exhaustive_primary"] = len(
            variants[3]["normalized_pair_edges"]
        )

        with self.assertRaisesRegex(evidence.EvidenceError, "more than 60"):
            self.validate(value, scale=61)

    def test_retrieval_evidence_rejects_silent_exhaustive_recovery(self) -> None:
        for scale in (61, 120, 250, 500):
            with self.subTest(scale=scale):
                value = group(scale=scale)
                variants = value["variants"]
                assert isinstance(variants, list)
                variants[7]["pair_counts"]["vocabulary_retrieval"] -= 1
                variants[7]["pair_counts"]["exhaustive_recovery"] = 1
                with self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "zero exhaustive recovery pairs",
                ):
                    self.validate(value, scale=scale)

    def test_exhaustive_recovery_is_unavailable_above_250_views(self) -> None:
        value = group(scale=500)
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[4]["accepted_attempt"] = "exhaustive_recovery"
        variants[4]["pair_counts"]["vocabulary_retrieval"] = 0
        variants[4]["pair_counts"]["exhaustive_recovery"] = len(
            variants[4]["normalized_pair_edges"]
        )

        with self.assertRaisesRegex(evidence.EvidenceError, "unavailable above 250"):
            self.validate(value, scale=500)

    def test_small_photo_evidence_requires_the_complete_exhaustive_pair_graph(self) -> None:
        value = group(scale=30)
        variants = value["variants"]
        assert isinstance(variants, list)
        shortened = variants[3]["normalized_pair_edges"][:-1]
        variants[3]["normalized_pair_edges"] = shortened
        variants[3]["normalized_pair_graph_sha256"] = pair_graph_digest(shortened)
        variants[3]["pair_counts"]["exhaustive_primary"] = len(shortened)
        variants[3]["scheduled_pair_count"] -= 1
        variants[3]["scheduled_pair_graph_sha256"] = pair_graph_digest(shortened)
        variants[3]["attempted_pair_count"] -= 1
        variants[3]["attempted_pair_graph_sha256"] = pair_graph_digest(shortened)
        variants[3]["raw_matched_pair_count"] = len(shortened)
        variants[3]["raw_matched_pair_graph_sha256"] = pair_graph_digest(shortened)
        variants[3]["spatially_verified_pair_count"] = len(shortened)

        with self.assertRaisesRegex(evidence.EvidenceError, "complete exhaustive"):
            self.validate(value, scale=30)

    def test_large_photo_evidence_requires_an_executed_retrieval_worker(self) -> None:
        value = group(scale=120)
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[5]["retrieval_worker_executed"] = False

        with self.assertRaisesRegex(evidence.EvidenceError, "vocabulary retrieval"):
            self.validate(value, scale=120)

    def test_large_photo_retrieval_allows_a_bounded_tie_edge_change(self) -> None:
        value = group(scale=120)
        variants = value["variants"]
        assert isinstance(variants, list)
        changed = variants[3]
        selected = changed["selected_content_ids"]
        assert isinstance(selected, list)
        prior_edges = changed["normalized_pair_edges"]
        assert isinstance(prior_edges, list)
        replacement = pair_edges(selected, 1, skip=500)[0]
        self.assertNotIn(replacement, prior_edges)

        def is_connected(edges: list[dict[str, str]]) -> bool:
            adjacency = {content_id: set() for content_id in selected}
            for edge in edges:
                adjacency[edge["content_a"]].add(edge["content_b"])
                adjacency[edge["content_b"]].add(edge["content_a"])
            reached = {selected[0]}
            pending = [selected[0]]
            while pending:
                for neighbor in adjacency[pending.pop()]:
                    if neighbor not in reached:
                        reached.add(neighbor)
                        pending.append(neighbor)
            return len(reached) == len(selected)

        edges = next(
            sorted(
                [
                    *prior_edges[:removed_index],
                    *prior_edges[removed_index + 1 :],
                    replacement,
                ],
                key=lambda edge: edge["edge_id"],
            )
            for removed_index in range(len(prior_edges))
            if is_connected(
                [
                    *prior_edges[:removed_index],
                    *prior_edges[removed_index + 1 :],
                    replacement,
                ]
            )
        )
        graph_digest = pair_graph_digest(edges)
        changed["normalized_pair_edges"] = edges
        changed["normalized_pair_graph_sha256"] = graph_digest
        changed["scheduled_pair_graph_sha256"] = graph_digest
        changed["attempted_pair_graph_sha256"] = graph_digest
        changed["raw_matched_pair_graph_sha256"] = graph_digest

        summary = self.validate(value, scale=120)

        self.assertGreaterEqual(summary["minimum_pair_graph_jaccard"], 0.98)

    def test_derived_stills_cannot_close_professional_photo_evidence(self) -> None:
        for source_kind in (
            "single_video_derived_stills",
            "multi_video_derived_stills",
            "mixed_derived_stills",
            "calibration_dataset_derived_stills",
        ):
            with self.subTest(source_kind=source_kind):
                value = group(source_kind=source_kind)
                with self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "cannot satisfy professional photo or RAW metadata closure",
                ):
                    self.validate(value)

    def test_legacy_undifferentiated_video_source_kind_is_rejected(self) -> None:
        value = group(source_kind="video_derived_stills")
        with self.assertRaisesRegex(evidence.EvidenceError, "source_kind is invalid"):
            self.validate(value)

    def test_release_coverage_requires_native_small_and_large_photo_groups(self) -> None:
        summary = evidence.validate_photo_permutation_release_coverage(
            [
                release_coverage_attestation(30),
                release_coverage_attestation(120),
            ]
        )

        self.assertEqual(summary["small_exhaustive"]["scale"], 30)
        self.assertEqual(summary["large_retrieval"]["scale"], 120)
        self.assertEqual(summary["source_kind"], "native_photos")

    def test_release_coverage_requires_the_designated_30_and_120_view_scales(self) -> None:
        for substitute_scale, missing_label in (
            (60, "small native-photo exhaustive"),
            (250, "large native-photo retrieval"),
        ):
            with self.subTest(substitute_scale=substitute_scale):
                receipts = [
                    release_coverage_attestation(30),
                    release_coverage_attestation(120),
                ]
                receipts[0 if substitute_scale <= 60 else 1] = (
                    release_coverage_attestation(substitute_scale)
                )
                with self.assertRaisesRegex(evidence.EvidenceError, missing_label):
                    evidence.validate_photo_permutation_release_coverage(receipts)

    def test_release_coverage_rejects_omission_and_one_sided_native_evidence(self) -> None:
        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "small native-photo exhaustive and large native-photo retrieval",
        ):
            evidence.validate_photo_permutation_release_coverage([])

        with self.assertRaisesRegex(evidence.EvidenceError, "large native-photo retrieval"):
            evidence.validate_photo_permutation_release_coverage(
                [release_coverage_attestation(30)]
            )

    def test_release_coverage_rejects_unattested_local_groups(self) -> None:
        candidate = release_coverage_attestation(30)
        candidate.pop("photo_permutation_supervisor_provenance")
        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "supervisor provenance",
        ):
            evidence.validate_photo_permutation_release_coverage([candidate])

    def test_release_coverage_rejects_missing_or_mismatched_source_authorization(
        self,
    ) -> None:
        missing = release_coverage_attestation(30)
        missing.pop("photo_permutation_source_authorization")
        with self.assertRaisesRegex(evidence.EvidenceError, "source authorization"):
            evidence.validate_photo_permutation_release_coverage([missing])

        mismatched = release_coverage_attestation(30)
        authorization = mismatched["photo_permutation_source_authorization"]
        assert isinstance(authorization, dict)
        authorization["origin_evidence_sha256"] = digest("forged-origin")
        with self.assertRaisesRegex(evidence.EvidenceError, "execution receipt"):
            evidence.validate_photo_permutation_release_coverage([mismatched])

    def test_derived_controls_cannot_substitute_for_native_release_evidence(self) -> None:
        receipts = []
        for scale, source_kind in (
            (30, "single_video_derived_stills"),
            (120, "multi_video_derived_stills"),
            (120, "mixed_derived_stills"),
            (120, "calibration_dataset_derived_stills"),
        ):
            receipts.append(
                release_coverage_attestation(
                    scale,
                    source_kind=source_kind,
                    category="object_orbit",
                )
            )

        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "small native-photo exhaustive and large native-photo retrieval",
        ):
            evidence.validate_photo_permutation_release_coverage(receipts)

    def test_calibration_dataset_control_closes_order_mechanics_only(self) -> None:
        request_value = request(scale=120, category="object_orbit")
        value = group(
            count=6,
            mode="development",
            scale=120,
            source_kind="calibration_dataset_derived_stills",
        )
        value["closure_claims"] = ["order_mechanics"]
        receipt = seal_group(value, request_value)

        summary = evidence.validate_photo_permutation_group(
            value,
            request_value,
            formal_release=False,
            execution_receipt=receipt,
        )

        self.assertEqual(summary["source_kind"], "calibration_dataset_derived_stills")
        self.assertEqual(summary["variant_count"], 6)

    def test_rejects_automatic_selected_content_set_drift(self) -> None:
        value = group()
        variants = value["variants"]
        assert isinstance(variants, list)
        replacement = opaque_digest("selection-drift")
        variants[6]["selected_content_ids"][-1] = replacement
        variants[6]["selected_content_ids"].sort()
        variants[6]["registered_content_ids"] = list(variants[6]["selected_content_ids"])
        variants[6]["selected_content_set_sha256"] = content_set_digest(
            variants[6]["selected_content_ids"]
        )
        variants[6]["registered_content_set_sha256"] = content_set_digest(
            variants[6]["registered_content_ids"]
        )
        edge_count = len(variants[6]["normalized_pair_edges"])
        variants[6]["normalized_pair_edges"] = pair_edges(
            variants[6]["selected_content_ids"], edge_count
        )
        variants[6]["normalized_pair_graph_sha256"] = pair_graph_digest(
            variants[6]["normalized_pair_edges"]
        )

        with self.assertRaisesRegex(evidence.EvidenceError, "selected content set"):
            self.validate(value)

    def test_rejects_mixed_canonical_observation_attestations(self) -> None:
        value = group()
        variants = value["variants"]
        assert isinstance(variants, list)
        variants[-1]["canonical_observation_attestation"] = opaque_digest(
            "different-canonical-observation"
        )

        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "canonical observation",
        ):
            self.validate(value)

    def test_rejects_registered_content_substitution_with_same_count(self) -> None:
        value = group()
        variants = value["variants"]
        assert isinstance(variants, list)
        registered = list(variants[6]["registered_content_ids"])
        registered[-1] = opaque_digest("not-selected")
        registered.sort()
        variants[6]["registered_content_ids"] = registered
        variants[6]["registered_content_set_sha256"] = content_set_digest(registered)

        with self.assertRaisesRegex(evidence.EvidenceError, "registered content IDs"):
            self.validate(value)

        value = group()
        variants = value["variants"]
        assert isinstance(variants, list)
        registered = list(variants[6]["registered_content_ids"])
        registered.pop()
        registered.append(variants[6]["selected_content_ids"][-2])
        variants[6]["registered_content_ids"] = sorted(set(registered))
        variants[6]["registered_views"] = len(variants[6]["registered_content_ids"])
        variants[6]["registered_content_set_sha256"] = content_set_digest(
            variants[6]["registered_content_ids"]
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "registered content set changed"):
            self.validate(value)

    def test_rejects_pair_edge_not_bound_to_selected_content(self) -> None:
        value = group()
        variants = value["variants"]
        assert isinstance(variants, list)
        selected = variants[2]["selected_content_ids"]
        bad = pair_edge(selected[0], opaque_digest("outside-selection"))
        variants[2]["normalized_pair_edges"][-1] = bad
        variants[2]["normalized_pair_edges"].sort(key=lambda edge: edge["edge_id"])
        variants[2]["normalized_pair_graph_sha256"] = pair_graph_digest(
            variants[2]["normalized_pair_edges"]
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "selected content IDs"):
            self.validate(value)

    def test_rejects_each_cross_variant_threshold_violation(self) -> None:
        mutations = (
            ("registered_views", 59, "registered-view loss"),
            ("residual_median_pixels", 0.551, "median residual delta"),
            ("residual_p90_pixels", 1.101, "p90 residual delta"),
            (
                "camera_center_p95_scene_radius_fraction",
                0.0101,
                "camera-center deviation",
            ),
            ("rotation_p95_degrees", 0.201, "rotation deviation"),
        )
        for field, value, message in mutations:
            with self.subTest(field=field):
                candidate = group()
                variants = candidate["variants"]
                assert isinstance(variants, list)
                if field == "registered_views":
                    registered = variants[8]["registered_content_ids"][:-2]
                    variants[8]["registered_content_ids"] = registered
                    variants[8]["registered_content_set_sha256"] = content_set_digest(
                        registered
                    )
                variants[8][field] = value
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    self.validate(candidate)

        candidate = group()
        variants = candidate["variants"]
        assert isinstance(variants, list)
        edge_count = len(variants[8]["normalized_pair_edges"])
        variants[8]["normalized_pair_edges"] = pair_edges(
            variants[8]["selected_content_ids"],
            edge_count,
            skip=4,
        )
        variants[8]["normalized_pair_graph_sha256"] = pair_graph_digest(
            variants[8]["normalized_pair_edges"]
        )
        with self.assertRaisesRegex(evidence.EvidenceError, "pair-graph Jaccard"):
            self.validate(candidate)

    def test_formal_mode_requires_twenty_variants_but_development_is_explicit(self) -> None:
        formal = group(count=3)
        with self.assertRaisesRegex(evidence.EvidenceError, "exactly 20 variants"):
            self.validate(formal)

        development = group(count=3, mode="development")
        development["variants"] = [
            variant(None, release_seed=False),
            variant(17, release_seed=False),
            variant(2, release_seed=False),
        ]
        development["closure_claims"] = ["order_mechanics"]
        receipt = seal_group(development)
        summary = evidence.validate_photo_permutation_group(
            development,
            request(),
            formal_release=False,
            execution_receipt=receipt,
        )
        self.assertEqual(summary["variant_count"], 3)

    def test_schema_matches_the_protocol_object(self) -> None:
        schema = json.loads(
            (ROOT / "scripts/benchmark/evidence.schema.json").read_text(encoding="utf-8")
        )
        self.assertIn("photoPermutationEvidence", schema["$defs"])
        value = group()
        seal_group(value)
        Draft202012Validator(
            {
                "$schema": schema["$schema"],
                "$defs": schema["$defs"],
                "$ref": "#/$defs/photoPermutationEvidence",
            }
        ).validate(value)
        calibration = group(
            count=6,
            mode="development",
            scale=120,
            source_kind="calibration_dataset_derived_stills",
        )
        calibration["closure_claims"] = ["order_mechanics"]
        seal_group(calibration)
        Draft202012Validator(
            {
                "$schema": schema["$schema"],
                "$defs": schema["$defs"],
                "$ref": "#/$defs/photoPermutationEvidence",
            }
        ).validate(calibration)

        from scripts.benchmark.tests import test_benchmark as benchmark_fixtures

        lane = evidence.LANE_REFERENCE
        prior_lpips_override = benchmark_fixtures.evidence.LPIPS_DISTANCE_OVERRIDE
        benchmark_fixtures.evidence.LPIPS_DISTANCE_OVERRIDE = (
            lambda _candidate, _target: 0.0
        )
        try:
            base_request = benchmark_fixtures.evidence_request(scale=30, lane=lane)
            observations = benchmark_fixtures.raw_observations(
                lane,
                request=base_request,
            )
            with tempfile.TemporaryDirectory() as temporary:
                artifact_root = Path(temporary)
                benchmark_fixtures.write_evidence_artifacts(
                    artifact_root,
                    observations,
                    render_request=base_request,
                )
                attestation = benchmark_fixtures.evidence.derive_attestation(
                    base_request,
                    observations,
                    artifact_root,
                    artifact_root / "attestation.json",
                    lane,
                    benchmark_fixtures.runner_identity(lane),
                    machine=benchmark_fixtures.evidence_machine(lane),
                )
        finally:
            benchmark_fixtures.evidence.LPIPS_DISTANCE_OVERRIDE = (
                prior_lpips_override
            )

        photo_request = benchmark_fixtures.evidence_request(
            scale=120,
            lane=lane,
            category="object_orbit",
            input_kind="photos",
            capture_traits=["unordered"],
        )
        for field in (
            "binding",
            "candidate_run_configuration",
            "category",
            "capture_traits",
            "holdout_indices",
            "reference_artifacts",
            "input_kind",
            "video_source_count",
        ):
            attestation[field] = photo_request[field]
        execution_receipt = seal_group(calibration, attestation)
        source_authorization = source_authorization_for(
            attestation,
            execution_receipt,
        )
        supervisor_provenance = {
            "schema_version": 1,
            "status": "verified",
            "repository": evidence.PHOTO_PERMUTATION_ATTESTATION_REPOSITORY,
            "signer_workflow": evidence.PHOTO_PERMUTATION_ATTESTATION_WORKFLOW,
            "source_commit": attestation["binding"]["git_commit"],
            "source_ref": "refs/heads/main",
            "subject_sha256": evidence.sha256_bytes(
                evidence.canonical_json_bytes(execution_receipt) + b"\n"
            ),
            "bundle_sha256": digest("calibration-execution-bundle"),
            "verified_attestation_count": 1,
            "source_authorization_subject_sha256": evidence.sha256_bytes(
                evidence.canonical_json_bytes(source_authorization) + b"\n"
            ),
            "source_authorization_bundle_sha256": digest(
                "calibration-source-authorization-bundle"
            ),
            "verified_source_authorization_attestation_count": 1,
        }
        attestation.update(
            {
                "photo_permutation": calibration,
                "photo_permutation_execution_receipt": execution_receipt,
                "photo_permutation_source_authorization": source_authorization,
                "photo_permutation_supervisor_provenance": supervisor_provenance,
            }
        )
        for artifact_name in (
            "photo_permutation_execution_receipt",
            "photo_permutation_attestation_bundle",
            "photo_permutation_source_authorization",
            "photo_permutation_source_authorization_attestation_bundle",
        ):
            attestation["artifacts"][artifact_name] = {
                "path": artifact_name + ".json",
                "sha256": digest(artifact_name),
                "bytes": 1,
            }
        benchmark_fixtures.validate_attestation_schema(attestation)

        photo_artifact_conditions = [
            item["then"]["properties"]["artifacts"]["required"]
            for item in schema["allOf"]
            if item.get("if", {}).get("required") == ["photo_permutation"]
        ]
        self.assertEqual(
            photo_artifact_conditions,
            [[
                "photo_permutation_execution_receipt",
                "photo_permutation_attestation_bundle",
                "photo_permutation_source_authorization",
                "photo_permutation_source_authorization_attestation_bundle",
            ]],
        )

    def test_github_attestation_verifier_binds_the_exact_execution_receipt(self) -> None:
        value = group()
        receipt = seal_group(value)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt_path = root / "photo-permutation-execution-receipt.json"
            receipt_path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
            bundle_path = root / "photo-permutation-attestation.jsonl"
            bundle_path.write_text("{}\n", encoding="utf-8")
            subject_hex = evidence.sha256_file(receipt_path).removeprefix("sha256:")
            verifier = root / "gh"
            verifier_arguments = root / "verifier-arguments.txt"
            verification = [
                {
                    "verificationResult": {
                        "statement": {
                            "subject": [
                                {
                                    "name": receipt_path.name,
                                    "digest": {"sha256": subject_hex},
                                }
                            ]
                        }
                    }
                }
            ]
            verifier.write_text(
                "#!/bin/sh\n"
                + "printf '%s\\n' \"$@\" > "
                + repr(str(verifier_arguments))
                + "\n"
                + "printf '%s\\n' "
                + repr(json.dumps(verification, separators=(",", ":")))
                + "\n",
                encoding="utf-8",
            )
            verifier.chmod(0o755)
            bound_request = request()
            bound_request["binding"] = {
                **bound_request["binding"],
                "git_commit": "1" * 40,
                "lane": "reference_m4_max",
                "profile": "release",
            }

            summary = evidence.verify_photo_permutation_github_attestation(
                receipt,
                receipt_path,
                bundle_path,
                bound_request,
                gh_executable=verifier,
                expected_gh_sha256=evidence.sha256_file(verifier),
            )

            self.assertEqual(summary["status"], "verified")
            self.assertEqual(summary["source_commit"], "1" * 40)
            self.assertEqual(summary["subject_sha256"], evidence.sha256_file(receipt_path))
            self.assertEqual(summary["bundle_sha256"], evidence.sha256_file(bundle_path))
            arguments = verifier_arguments.read_text(encoding="utf-8").splitlines()
            self.assertEqual(arguments[:2], ["attestation", "verify"])
            self.assertEqual(
                arguments[arguments.index("--repo") + 1],
                "dud8/EasySplat",
            )
            self.assertEqual(
                arguments[arguments.index("--signer-workflow") + 1],
                "dud8/EasySplat/.github/workflows/benchmark-release.yml",
            )
            self.assertEqual(
                arguments[arguments.index("--source-digest") + 1],
                "1" * 40,
            )
            self.assertEqual(
                arguments[arguments.index("--source-ref") + 1],
                "refs/heads/main",
            )

    def test_github_attestation_verifier_rejects_a_different_subject(self) -> None:
        value = group()
        receipt = seal_group(value)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt_path = root / "photo-permutation-execution-receipt.json"
            receipt_path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
            bundle_path = root / "photo-permutation-attestation.jsonl"
            bundle_path.write_text("{}\n", encoding="utf-8")
            verifier = root / "gh"
            verifier.write_text(
                "#!/bin/sh\nprintf '%s\\n' "
                + repr(
                    json.dumps(
                        [
                            {
                                "verificationResult": {
                                    "statement": {
                                        "subject": [
                                            {
                                                "name": receipt_path.name,
                                                "digest": {"sha256": "0" * 64},
                                            }
                                        ]
                                    }
                                }
                            }
                        ],
                        separators=(",", ":"),
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            verifier.chmod(0o755)
            bound_request = request()
            bound_request["binding"] = {
                **bound_request["binding"],
                "git_commit": "1" * 40,
                "lane": "reference_m4_max",
                "profile": "release",
            }

            with self.assertRaisesRegex(evidence.EvidenceError, "subject"):
                evidence.verify_photo_permutation_github_attestation(
                    receipt,
                    receipt_path,
                    bundle_path,
                    bound_request,
                    gh_executable=verifier,
                    expected_gh_sha256=evidence.sha256_file(verifier),
                )

    def test_github_attestation_verifier_requires_an_independent_binary_pin(
        self,
    ) -> None:
        value = group()
        receipt = seal_group(value)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt_path = root / "photo-permutation-execution-receipt.json"
            receipt_path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
            bundle_path = root / "photo-permutation-attestation.jsonl"
            bundle_path.write_text("{}\n", encoding="utf-8")
            verifier = root / "gh"
            verifier.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            verifier.chmod(0o755)
            bound_request = request()
            bound_request["binding"] = {
                **bound_request["binding"],
                "git_commit": "1" * 40,
                "lane": "reference_m4_max",
                "profile": "release",
            }

            with self.assertRaisesRegex(evidence.EvidenceError, "digest pin"):
                evidence.verify_photo_permutation_github_attestation(
                    receipt,
                    receipt_path,
                    bundle_path,
                    bound_request,
                    gh_executable=verifier,
                )

    def test_github_attestation_verifier_rejects_a_wrong_binary_pin_before_execution(
        self,
    ) -> None:
        attestation = release_coverage_attestation(30)
        receipt = attestation["photo_permutation_execution_receipt"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt_path = root / "photo-permutation-execution-receipt.json"
            receipt_path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
            bundle_path = root / "photo-permutation-attestation.jsonl"
            bundle_path.write_text("{}\n", encoding="utf-8")
            marker = root / "executed"
            verifier = root / "gh"
            verifier.write_text(
                f"#!/bin/sh\nprintf ran > {str(marker)!r}\n",
                encoding="utf-8",
            )
            verifier.chmod(0o755)

            with self.assertRaisesRegex(evidence.EvidenceError, "unsafe"):
                evidence.verify_photo_permutation_github_attestation(
                    receipt,
                    receipt_path,
                    bundle_path,
                    attestation,
                    gh_executable=verifier,
                    expected_gh_sha256=digest("wrong-verifier"),
                )
            self.assertFalse(marker.exists())

    def test_source_authorization_uses_a_distinct_exact_attestation_subject(
        self,
    ) -> None:
        attestation = release_coverage_attestation(30)
        authorization = attestation["photo_permutation_source_authorization"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authorization_path = (
                root / "photo-permutation-source-authorization.json"
            )
            authorization_path.write_bytes(
                evidence.canonical_json_bytes(authorization) + b"\n"
            )
            bundle_path = (
                root / "photo-permutation-source-authorization-attestation.jsonl"
            )
            bundle_path.write_text("{}\n", encoding="utf-8")
            verifier = root / "gh"
            verifier.write_text(
                "#!/usr/bin/python3\n"
                "import hashlib, json, pathlib, sys\n"
                "path = pathlib.Path(sys.argv[3])\n"
                "digest = hashlib.sha256(path.read_bytes()).hexdigest()\n"
                "print(json.dumps([{'verificationResult': {'statement': "
                "{'subject': [{'name': path.name, 'digest': {'sha256': digest}}]}}}], "
                "separators=(',', ':')))\n",
                encoding="utf-8",
            )
            verifier.chmod(0o755)
            verifier_sha256 = evidence.sha256_file(verifier)
            assert isinstance(authorization, dict)
            authorization["gh_verifier_sha256"] = verifier_sha256
            authorization_path.write_bytes(
                evidence.canonical_json_bytes(authorization) + b"\n"
            )

            summary = (
                evidence.verify_photo_permutation_source_authorization_github_attestation(
                    authorization,
                    authorization_path,
                    bundle_path,
                    attestation,
                    gh_executable=verifier,
                    expected_gh_sha256=verifier_sha256,
                )
            )
            self.assertEqual(
                summary["subject_sha256"],
                evidence.sha256_file(authorization_path),
            )

            with self.assertRaisesRegex(evidence.EvidenceError, "canonical"):
                evidence.verify_photo_permutation_source_authorization_github_attestation(
                    authorization,
                    authorization_path,
                    root / "photo-permutation-attestation.jsonl",
                    attestation,
                    gh_executable=verifier,
                    expected_gh_sha256=verifier_sha256,
                )


class PhotoPermutationUtilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = {
            "schema_version": 1,
            "corpus_id": "healthy-house-01",
            "entries": [
                {"relative_path": "camera-a/IMG_0001.JPG", "source_sha256": digest("a")},
                {"relative_path": "camera-a/IMG_0002.JPG", "source_sha256": digest("b")},
                {"relative_path": "camera-b/IMG_0301.HEIC", "source_sha256": digest("c")},
            ],
        }

    def test_mapping_is_deterministic_name_free_and_does_not_touch_sources(self) -> None:
        self.assertTrue(
            hasattr(evidence, "build_photo_permutation_mapping"),
            "photo permutation utility is not implemented",
        )
        first = evidence.build_photo_permutation_mapping(
            self.manifest,
            scale=61,
            permutation_index=7,
            permutation_seed=8675309,
        )
        second = evidence.build_photo_permutation_mapping(
            copy.deepcopy(self.manifest),
            scale=61,
            permutation_index=7,
            permutation_seed=8675309,
        )

        self.assertEqual(first, second)
        serialized = evidence.canonical_json_bytes(first).decode("utf-8")
        self.assertNotIn("IMG_0001", serialized)
        self.assertNotIn("camera-a", serialized)
        self.assertEqual(first["operation"], "mapping_only")
        self.assertEqual(
            [entry["target_relative_path"] for entry in first["entries"]],
            ["photo-000001.jpg", "photo-000002.jpg", "photo-000003.heic"],
        )
        for entry in first["entries"]:
            self.assertEqual(
                set(entry),
                {"source_sha256", "order_key_sha256", "target_relative_path"},
            )

        different_index = evidence.build_photo_permutation_mapping(
            self.manifest,
            scale=61,
            permutation_index=8,
            permutation_seed=8675309,
        )
        self.assertNotEqual(first["order_manifest_sha256"], different_index["order_manifest_sha256"])

    def test_atomic_writer_emits_one_bounded_canonical_receipt(self) -> None:
        mapping = evidence.build_photo_permutation_mapping(
            self.manifest,
            scale=61,
            permutation_index=1,
            permutation_seed=42,
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "mapping.json"
            evidence.write_photo_permutation_mapping(output, mapping)
            self.assertEqual(
                output.read_bytes(),
                evidence.canonical_json_bytes(mapping) + b"\n",
            )
            self.assertLess(output.stat().st_size, 8 * 1024 * 1024)

    def test_atomic_writer_revalidates_the_mapping_before_publication(self) -> None:
        mapping = evidence.build_photo_permutation_mapping(
            self.manifest,
            scale=61,
            permutation_index=1,
            permutation_seed=42,
        )
        mapping["entries"][0]["source_path"] = "/Users/private/IMG_0001.JPG"
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(evidence.EvidenceError, "invalid fields"):
                evidence.write_photo_permutation_mapping(
                    Path(temporary) / "mapping.json",
                    mapping,
                )

    def test_rejects_unsafe_paths_and_digest_collisions(self) -> None:
        unsafe = copy.deepcopy(self.manifest)
        unsafe["entries"][0]["relative_path"] = "/Users/private/IMG_0001.JPG"
        with self.assertRaisesRegex(evidence.EvidenceError, "safe relative path"):
            evidence.build_photo_permutation_mapping(
                unsafe,
                scale=61,
                permutation_index=1,
                permutation_seed=42,
            )

        collision = copy.deepcopy(self.manifest)
        collision["entries"][1]["source_sha256"] = collision["entries"][0][
            "source_sha256"
        ]
        with self.assertRaisesRegex(evidence.EvidenceError, "source digest collision"):
            evidence.build_photo_permutation_mapping(
                collision,
                scale=61,
                permutation_index=1,
                permutation_seed=42,
            )


if __name__ == "__main__":
    unittest.main()
