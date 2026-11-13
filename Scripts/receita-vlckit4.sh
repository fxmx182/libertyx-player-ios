#!/bin/bash
# Imprime a "receita" do nosso VLCKit 4: 12 caracteres da soma do script de
# compilação e dos nossos remendos no libVLC. O release vlckit4-<tag> leva a
# receita com que foi feito (asset RECEITA); um build do app só vai ao
# TestFlight se a receita do release for a do commit — senão o app sairia
# com o motor de antes do remendo.
set -euo pipefail
cd "$(dirname "$0")"
cat compilar-vlckit4.sh vlckit4-remendos/*.patch | shasum -a 256 | cut -c1-12
