#!/usr/bin/env python3
"""Conversa com a API da App Store Connect usando a chave da equipe.

Sem Mac: o certificado de distribuição, o perfil e o identificador do app
saem daqui, pela API, e vão para os segredos do repositório. O CI só usa.

    asc.py GET /v1/bundleIds
    asc.py POST /v1/bundleIds '{"data": {...}}'

Variáveis: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (o .p8). Precisa de
pyjwt, cryptography e requests (o venv em toolchain/asc-venv tem os três).
"""
import json
import os
import sys
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com"


def token() -> str:
    agora = int(time.time())
    with open(os.environ["ASC_KEY_PATH"]) as f:
        chave = f.read()
    # A Apple recusa token com mais de 20 minutos de validade.
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": agora, "exp": agora + 15 * 60,
         "aud": "appstoreconnect-v1"},
        chave, algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def chamar(metodo: str, caminho: str, corpo: dict | None = None) -> dict:
    r = requests.request(metodo, BASE + caminho, json=corpo,
                         headers={"Authorization": f"Bearer {token()}"}, timeout=60)
    if r.status_code >= 400:
        sys.stderr.write(f"{r.status_code} {r.text}\n")
        raise SystemExit(1)
    return r.json() if r.content else {}


if __name__ == "__main__":
    metodo, caminho = sys.argv[1], sys.argv[2]
    corpo = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    print(json.dumps(chamar(metodo, caminho, corpo), indent=2, ensure_ascii=False))
