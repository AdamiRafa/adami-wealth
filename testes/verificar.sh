#!/usr/bin/env bash
# Verificações antes de publicar (passo 7 da 3.20). Roda sozinho na publicação
# (.github/publicar-hostgator.sh chama este arquivo antes de enviar qualquer coisa).
# Se algum passo falhar, nada vai ao ar: o erro aparece na aba Actions do GitHub.
#
#  1. sintaxe de cada <script> e de comum/*.js (node --check)
#  2. variável usada sem declaração (testes/escopo.js --estrito)
#  3. SQL de todos os .sql (pglast)
#  4. teste de fumaça: os 15 módulos abertos num Chromium, com o Supabase simulado
#
# Uso local (com as ferramentas já instaladas): bash testes/verificar.sh
# Na publicação: VERIFICAR_INSTALAR=1 instala acorn, eslint-scope, playwright e pglast.
set -euo pipefail
cd "$(dirname "$0")/.."
RAIZ="$(pwd)"

if [ "${VERIFICAR_INSTALAR:-}" = "1" ]; then
  echo "== Instalando as ferramentas de teste"
  FERR="$(mktemp -d)"
  (cd "$FERR" && npm init -y >/dev/null && npm install --no-audit --no-fund --silent acorn@8.18.0 eslint-scope@9.1.2 playwright@1.63.0 >/dev/null)
  (cd "$FERR" && npx --yes playwright install --with-deps chromium >/dev/null)
  python3 -m venv "$FERR/py"
  "$FERR/py/bin/pip" install --quiet --disable-pip-version-check pglast==8.7
  export PATH="$FERR/py/bin:$PATH"
  export NODE_PATH="$FERR/node_modules"
else
  export NODE_PATH="/opt/node-tools/node_modules${NODE_PATH:+:$NODE_PATH}"
fi

echo "== 1 e 2. Sintaxe e escopo"
for f in *.html; do node testes/escopo.js "$f" --estrito; done
for f in comum/*.js; do node --check "$f"; done
echo "comum/*.js: sintaxe ok"

echo "== 3. SQL"
python3 - <<'PY'
import glob, sys, pglast
erros = 0
for f in sorted(glob.glob('*.sql') + glob.glob('supabase/**/*.sql', recursive=True)):
    try:
        pglast.parse_sql(open(f, encoding='utf-8').read())
    except Exception as e:
        erros += 1; print('ERRO', f, str(e)[:200])
print('SQL: %s' % ('ok' if not erros else '%d arquivo(s) com erro' % erros))
sys.exit(1 if erros else 0)
PY

echo "== 4. Teste de fumaça"
PORTA=8799
python3 -m http.server "$PORTA" --bind 127.0.0.1 --directory "$RAIZ" >/dev/null 2>&1 &
SERV=$!
trap 'kill $SERV 2>/dev/null || true' EXIT
for i in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORTA/index.html" && break; sleep 0.3; done
node testes/fumaca.js "http://127.0.0.1:$PORTA"
echo "== Tudo certo."
