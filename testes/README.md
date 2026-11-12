# Verificações antes de publicar

`escopo.js` faz o passo 1 e o passo 2 do CLAUDE.md ("Antes de publicar") para um arquivo HTML:
`node --check` em cada `<script>` e variáveis usadas sem declaração (acorn + eslint-scope).

```
NODE_PATH=/opt/node-tools/node_modules node testes/escopo.js crm.html
for f in *.html; do NODE_PATH=/opt/node-tools/node_modules node testes/escopo.js $f; done
```

Nomes do navegador que o script não conhece (ex.: `HashChangeEvent`, `ClipboardItem`) e as bibliotecas
embutidas do `imobiliario.html` aparecem na lista sem ser erro. Qualquer outro nome é variável sem
declaração: não publique.

Os testes de tela (Playwright com o Supabase simulado) e a medição de margens da impressão estão
descritos na seção 26 do `DOCUMENTACAO.md`; o roteiro do manual em `manual-fonte/LEIA-ME.md`.

## Tudo de uma vez (3.20)

```
bash testes/verificar.sh
```

Roda sintaxe e escopo (`--estrito`) de todo HTML, sintaxe de `comum/*.js`, SQL (pglast) e o teste de fumaça
(`fumaca.js`: os 15 módulos num Chromium, com o Supabase simulado de `simulador.js`). A publicação chama este
mesmo script com `VERIFICAR_INSTALAR=1`, que instala as ferramentas antes. Se falhar, nada é publicado.
