set -e
node gerar.js >/dev/null
python3 paginas.py miolo1.pdf 2>/dev/null
node final.js
python3 paginas.py miolo.pdf 2>/dev/null
python3 - <<'PY'
import pypdf
w=pypdf.PdfWriter(); c=pypdf.PdfReader('capa.pdf'); m=pypdf.PdfReader('miolo.pdf')
w.add_page(c.pages[0])
for pg in m.pages: w.add_page(pg)
w.add_page(c.pages[1])
w.add_metadata({'/Title':'Manual do Hub Adami','/Author':'Adami Captal','/Subject':'Guia do assessor, versão 3.11'})
w.compress_identical_objects() if hasattr(w,'compress_identical_objects') else None
w.write('Manual do Hub Adami.pdf'); print(len(w.pages),'paginas')
PY
ls -la "Manual do Hub Adami.pdf" | awk '{print $5/1e6" MB"}'
