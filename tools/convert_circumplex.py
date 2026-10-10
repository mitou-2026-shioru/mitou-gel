import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
import numpy as np


def convert(source, destination):
    data = source.read_bytes()
    original = json.loads(data)
    if original.get("type") != "standardized_mlp_classifier" or original.get("activation") != "relu":
        raise ValueError("Expected standardized ReLU MLP")
    features = original["features"]
    classes = original["classes"]
    mean = np.asarray(original["mean"], dtype=np.float64)
    scale = np.maximum(np.asarray(original["scale"], dtype=np.float64), 1e-12)
    weights = [np.asarray(layer, dtype=np.float64) for layer in original["coefs"]]
    biases = [np.asarray(layer, dtype=np.float64) for layer in original["intercepts"]]
    if len(features) != 68 or len(classes) != 6 or len(weights) != 2:
        raise ValueError("Unexpected model dimensions")
    if weights[0].shape != (68, 64) or weights[1].shape != (64, 6):
        raise ValueError("Unexpected layer shapes")
    arrays = [mean, scale, *weights, *biases]
    if not all(np.isfinite(array).all() for array in arrays):
        raise ValueError("Non-finite model parameters")
    builder = NeuralNetworkBuilder([("features", datatypes.Array(68))], [("probabilities", datatypes.Array(6))])
    standardized_weights = weights[0].T / scale[None, :]
    standardized_bias = biases[0] - standardized_weights @ mean
    builder.add_inner_product("hidden", standardized_weights, standardized_bias, 68, 64, True, "features", "hidden")
    builder.add_activation("relu", "RELU", "hidden", "activated")
    builder.add_inner_product("logits", weights[1].T, biases[1], 64, 6, True, "activated", "logits")
    builder.add_softmax("softmax", "logits", "probabilities")
    model = ct.models.MLModel(builder.spec, compute_units=ct.ComputeUnit.CPU_ONLY)
    model.short_description = "tiny-lm acoustic-feature MLP; research classification, not a haptic controller"
    revision = subprocess.check_output(["git", "-C", str(source.parent.parent), "rev-parse", "HEAD"], text=True).strip()
    model.user_defined_metadata["source_revision"] = revision
    model.user_defined_metadata["source_sha256"] = hashlib.sha256(data).hexdigest()
    generator = np.random.default_rng(42)
    maximum_error = 0.0
    for normalized in [np.zeros(68), *generator.normal(size=(32, 68))]:
        inputs = (mean + normalized * scale).astype(np.float32)
        hidden = np.maximum(((inputs.astype(np.float64) - mean) / scale) @ weights[0] + biases[0], 0)
        logits = hidden @ weights[1] + biases[1]
        expected = np.exp(logits - logits.max())
        expected /= expected.sum()
        actual = np.asarray(model.predict({"features": inputs})["probabilities"]).reshape(-1)
        maximum_error = max(maximum_error, float(np.max(np.abs(actual - expected))))
    if maximum_error > 0.0005:
        raise ValueError(f"Core ML parity failure: {maximum_error}")
    destination.mkdir(parents=True, exist_ok=True)
    model.save(str(destination / "VoiceCircumplex.mlmodel"))
    metadata = {
        "features": features,
        "classes": classes,
        "prototypes": original["prototypes"],
        "source_repository": "mitou-2026-shioru/tiny-lm",
        "source_revision": revision,
        "source_path": "public/circumplex-model.json",
        "source_sha256": hashlib.sha256(data).hexdigest(),
        "coremltools_version": ct.__version__,
        "conversion_check": {"cases": 33, "maximum_probability_error": maximum_error},
        "source_license": "No LICENSE file found; redistribution terms unconfirmed",
        "evaluation": "Japanese live microphone accuracy unverified"
    }
    (destination / "VoiceCircumplex.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(metadata["conversion_check"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    convert(arguments.source, arguments.destination)
