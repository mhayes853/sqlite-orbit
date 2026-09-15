#!/usr/bin/env python3

import argparse
import copy
import json
import shutil
from pathlib import Path


def copy_entry(source, destination):
    if source.is_dir():
        destination.mkdir(exist_ok=True)
        for child in source.iterdir():
            copy_entry(child, destination / child.name)
    elif destination.exists():
        if source.read_bytes() != destination.read_bytes():
            raise ValueError(f"conflicting shared file {source.name}")
    else:
        shutil.copy2(source, destination)


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Merge compatible Turso static-library artifact bundles."
    )
    parser.add_argument("output", type=Path)
    parser.add_argument("bundles", type=Path, nargs="+")
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    output = arguments.output.resolve()
    bundles = [bundle.resolve() for bundle in arguments.bundles]
    if output.exists():
        raise ValueError(f"refusing to overwrite {output}")
    if output.suffix != ".artifactbundle":
        raise ValueError("output must end in .artifactbundle")

    metadata = None
    variants = []
    seen_triples = set()
    output.mkdir(parents=True)

    for bundle in bundles:
        bundle_metadata = json.loads((bundle / "info.json").read_text())
        artifact = bundle_metadata["artifacts"]["TursoSQLite3"]
        if metadata is None:
            metadata = copy.deepcopy(bundle_metadata)
            metadata["artifacts"]["TursoSQLite3"]["variants"] = variants
        elif (
            bundle_metadata["schemaVersion"] != metadata["schemaVersion"]
            or artifact["version"]
            != metadata["artifacts"]["TursoSQLite3"]["version"]
            or artifact["type"] != "staticLibrary"
        ):
            raise ValueError(f"incompatible bundle metadata in {bundle}")

        for variant in artifact["variants"]:
            triples = set(variant["supportedTriples"])
            if triples & seen_triples:
                raise ValueError(f"duplicate supported triple in {bundle}")
            seen_triples |= triples
            variants.append(variant)

        for path in bundle.iterdir():
            if path.name == "info.json":
                continue
            copy_entry(path, output / path.name)

    (output / "info.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
