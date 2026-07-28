import csv

with open('output/train_features.csv', newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    headers = reader.fieldnames
    rows = list(reader)

# Buscar columnas que contengan 'kind' en el nombre
kind_like = [c for c in headers if 'kind' in c.lower()]
print('Columnas con "kind" en el nombre:', len(kind_like))
for c in kind_like:
    print('  repr=%r' % c)

print()
# Mostrar cols 31-38 (alrededor de structure_above_kind_1m)
print('Cols 31-38 del CSV:')
for i in range(30, min(38, len(headers))):
    c = headers[i]
    vals = [r[c] for r in rows if r.get(c,'').strip()][:3]
    empty = sum(1 for r in rows if not r.get(c,'').strip())
    print('  col%d: repr=%-50r  empty=%d  sample=%s' % (i+1, c, empty, vals))
