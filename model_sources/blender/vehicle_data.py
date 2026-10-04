"""Runtime stage dimensions and rig expectations, exported by tools/craftspec.gd."""
import json
import os

_data = None


def vehicle_stages(vehicle):
    global _data
    if _data is None:
        path = os.environ.get('ASTRARIUM_CRAFT_SPEC')
        if not path:
            raise RuntimeError('Build vehicles with model_sources/blender/build.sh; '
                               'ASTRARIUM_CRAFT_SPEC must name its runtime catalogue export')
        with open(path, encoding='utf-8') as source:
            _data = json.load(source)
        if _data.get('version') != 1:
            raise ValueError('Unsupported craft specification version')
    return _data['vehicles'][vehicle]
