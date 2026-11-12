import pdfplumber,json,logging,sys
logging.disable(logging.CRITICAL)
ids={'01':'c1','02':'c2','03':'c3','04':'c4','05':'c5','06':'c6','07':'c7','08':'c8','09':'c9','10':'c10','11':'c11','12':'c12','13':'c13','14':'c14','15':'c15','16':'c16','17':'c17','A':'c18'}
P={}
with pdfplumber.open(sys.argv[1]) as pdf:
    for i,pg in enumerate(pdf.pages):
        for w in pg.extract_words(extra_attrs=['size']):
            if w['size']>=30 and w['text'] in ids and ids[w['text']] not in P: P[ids[w['text']]]=i+1
json.dump(P,open('paginas.json','w')); print(P)
