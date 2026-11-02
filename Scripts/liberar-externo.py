#!/usr/bin/env python3
"""Libera um build do TestFlight para o grupo externo (Família e amigos).

O grupo interno recebe todo build sozinho; o externo não: cada build novo
precisa entrar no grupo, ganhar o texto do "O que testar" e ir para a revisão
beta da Apple. É o que este script faz, esperando o build sair do
processamento antes.

    liberar-externo.py 12 "O que mudou neste build."

Mesmas variáveis do asc.py.
"""
import sys
import time

from asc import chamar

APP = "6826934911"
GRUPO_EXTERNO = "7ea05856-66ba-413b-961a-384e2096787f"


def esperar_build(numero: str) -> str:
    # O build aparece na API alguns minutos depois do envio, e só pode ir para
    # o grupo quando o processamento termina (VALID).
    for _ in range(80):
        r = chamar("GET", f"/v1/builds?filter[app]={APP}&filter[version]={numero}"
                          "&fields[builds]=processingState")
        if r["data"]:
            build = r["data"][0]
            estado = build["attributes"]["processingState"]
            if estado == "VALID":
                return build["id"]
            if estado in ("FAILED", "INVALID"):
                raise SystemExit(f"build {numero}: {estado}")
        time.sleep(30)
    raise SystemExit(f"build {numero} não ficou pronto em 40 minutos")


def main() -> None:
    numero, novidades = sys.argv[1], sys.argv[2]
    build = esperar_build(numero)

    # A Apple cria a localização pt-BR sozinha; criar outra dá 409.
    locais = chamar("GET", f"/v1/builds/{build}/betaBuildLocalizations")["data"]
    if locais:
        for local in locais:
            chamar("PATCH", f"/v1/betaBuildLocalizations/{local['id']}", {"data": {
                "type": "betaBuildLocalizations", "id": local["id"],
                "attributes": {"whatsNew": novidades}}})
    else:
        chamar("POST", "/v1/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "pt-BR", "whatsNew": novidades},
            "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})

    chamar("POST", f"/v1/betaGroups/{GRUPO_EXTERNO}/relationships/builds",
           {"data": [{"type": "builds", "id": build}]})
    r = chamar("POST", "/v1/betaAppReviewSubmissions", {"data": {
        "type": "betaAppReviewSubmissions",
        "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})
    print(f"build {numero} no grupo externo, revisão: {r['data']['attributes']['betaReviewState']}")


if __name__ == "__main__":
    main()
