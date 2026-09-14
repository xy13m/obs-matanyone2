# Licensing notice

This repository contains two kinds of material with different licenses.

## Plugin source code: GPL-3.0-or-later

Everything committed to this repository (the OBS filter, the Swift bridge,
the benchmark, the scripts and the documentation) is licensed under the GNU
General Public License, version 3 or later. See `LICENSE`.

The plugin links against [MatAnyone2Kit](https://github.com/flowtyone/MatAnyone2Kit),
which is GPL-3.0. We use a fork at <https://github.com/xy13m/MatAnyone2Kit>
pinned to a specific revision in `Package.swift`.

## MatAnyone 2 model weights: NTU S-Lab License 1.0, non-commercial

The Core ML models the plugin runs are a conversion of the
[MatAnyone2](https://github.com/pq-yang/MatAnyone2) weights published by
S-Lab, Nanyang Technological University. Those weights are licensed under the
NTU S-Lab License 1.0, which permits non-commercial use only. Converting them
to Core ML does not change their license.

The weights are not committed to this repository and must not be
redistributed with it. `scripts/export-models.sh` downloads them from the
upstream release and exports the Core ML models on your machine. The upstream
license text is copied next to the exported models.

Using this plugin with those weights is therefore non-commercial only. For
commercial use of the weights, contact the MatAnyone2 authors.
