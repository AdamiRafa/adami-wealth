# Fonte do Manual do Hub

O PDF publicado fica em `ajuda/Manual-do-Hub.pdf` (botão ? e Primeiros passos apontam para ele).
Esta pasta não vai para o site (o `.github/publicar-hostgator.sh` só publica a lista dele).

- `manual.html`: o texto e o layout (A4, `@page` com margem 20/18/22/18 mm).
- `capa.html`: capa e contracapa (página com margem zero, sangrando).
- `imgj/`: as telas, em JPEG, com dados fictícios (Família Exemplo, Ana Ribeiro).
- `captura/`: os scripts Playwright que tiraram as telas, com o Supabase simulado (`mock.js`).
  O CRM foi capturado no modo de demonstração (cópia do `crm.html` com `MODO_DEMO = true`).

## Gerar o PDF

Na pasta `manual-fonte/`, com um servidor local servindo a pasta na porta 8771:

```
python3 -m http.server 8771 --bind 127.0.0.1 &
bash tudo.sh
```

`tudo.sh` gera o miolo, acha a página de cada capítulo (`paginas.py`), gera de novo com os números
no sumário, junta capa + miolo + contracapa e grava `Manual do Hub Adami.pdf`. Copie para
`ajuda/Manual-do-Hub.pdf`. Depois meça as margens (CLAUDE.md, passo 4) e, se as páginas dos
capítulos mudaram, atualize `AJUDA[...].pag` em `comum/barra.js` (página do PDF final, contando a capa).
