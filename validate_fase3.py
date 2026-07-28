#!/usr/bin/env python3
"""
validate_fase3.py — Validacion completa Fase 3 (Paso 3 del spec)

1. train normalizado: mean≈0, std≈1 para cada columna numerica (tol ±0.01)
2. test normalizado:  mean/std NO son ≈0/1 (usa params de train) — muestra 4 columnas
3. Celdas vacias en original → siguen vacias en normalizado (no 0, no NaN-string)
4. Columnas *_kind y targets IDENTICAS entre original y normalizado
5. 2 filas reales completas antes/despues
"""
import csv, math, json
from collections import defaultdict

# ── rutas ──────────────────────────────────────────────────────────────────
TRAIN_ORIG   = "output/train_features.csv"
TEST_ORIG    = "output/test_features.csv"
TRAIN_NORM   = "output/train_features_normalized.csv"
TEST_NORM    = "output/test_features_normalized.csv"
PARAMS_JSON  = "output/normalization_params.json"

TARGETS = {"trails_3m", "trails_5m", "trails_10m", "trails_15m"}

def classify(col):
    if col in TARGETS:    return "TARGET"
    if "kind" in col:     return "CATEGORICAL"
    return "NUMERIC"

def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        headers = reader.fieldnames or list(rows[0].keys()) if rows else []
    # recover headers from DictReader
    with open(path, newline="", encoding="utf-8") as f:
        headers = next(csv.reader(f))
    return headers, rows

def is_numeric_str(s):
    try:
        float(s)
        return True
    except (ValueError, TypeError):
        return False

SEP = "=" * 72

# ── Cargar todo ─────────────────────────────────────────────────────────────
print(f"\n{SEP}")
print("CARGANDO ARCHIVOS")
print(SEP)
train_hdrs, train_orig  = read_csv(TRAIN_ORIG)
_,          train_nrm   = read_csv(TRAIN_NORM)
test_hdrs,  test_orig   = read_csv(TEST_ORIG)
_,          test_nrm    = read_csv(TEST_NORM)
with open(PARAMS_JSON, encoding="utf-8") as f:
    params = json.load(f)

print(f"  train_orig  : {len(train_orig):4d} filas, {len(train_hdrs)} cols")
print(f"  train_norm  : {len(train_nrm):4d} filas, {len(train_hdrs)} cols")
print(f"  test_orig   : {len(test_orig):4d} filas, {len(test_hdrs)} cols")
print(f"  test_norm   : {len(test_nrm):4d} filas, {len(test_hdrs)} cols")
print(f"  params cols : {len(params)} columnas en JSON")

num_cols  = [c for c in train_hdrs if classify(c) == "NUMERIC"  and c in params]
cat_cols  = [c for c in train_hdrs if classify(c) == "CATEGORICAL"]
tgt_cols  = [c for c in train_hdrs if classify(c) == "TARGET"]
empty_cols = [c for c in train_hdrs if classify(c) == "NUMERIC" and c not in params]

print(f"\n  Columnas numericas con params : {len(num_cols)}")
print(f"  Columnas 100% vacias (excluidas): {len(empty_cols)} → {empty_cols}")
print(f"  Columnas categoricas           : {len(cat_cols)}")
print(f"  Columnas target                : {len(tgt_cols)}")

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 1 — train_norm: mean≈0, std≈1 (tol ±0.01)
# ═══════════════════════════════════════════════════════════════════════════
print(f"\n{SEP}")
print("CHECK 1 — train_norm: mean≈0 y std≈1 para columnas normalizadas (tol ±0.01)")
print(SEP)

TOL = 0.01
check1_ok = True
fails_mean = []
fails_std  = []

col_vals_train = defaultdict(list)
for row in train_nrm:
    for col in num_cols:
        v = row.get(col, "").strip()
        if is_numeric_str(v):
            col_vals_train[col].append(float(v))

print(f"  {'Columna':<52} {'N':>5} {'mean':>10} {'std':>10} {'mean_ok':>8} {'std_ok':>7}")
print(f"  {'-'*52} {'-'*5} {'-'*10} {'-'*10} {'-'*8} {'-'*7}")

for col in num_cols:
    vals = col_vals_train[col]
    n = len(vals)
    if n < 2:
        print(f"  {col:<52} {n:>5} {'N/A':>10} {'N/A':>10} {'SKIP':>8} {'SKIP':>7}")
        continue
    mean = sum(vals) / n
    std  = math.sqrt(sum((v - mean)**2 for v in vals) / n)
    m_ok = abs(mean) <= TOL
    s_ok = abs(std - 1.0) <= TOL
    flag = "" if (m_ok and s_ok) else "  ← FALLO"
    print(f"  {col:<52} {n:>5} {mean:>10.6f} {std:>10.6f} {'OK' if m_ok else 'FAIL':>8} {'OK' if s_ok else 'FAIL':>7}{flag}")
    if not m_ok:
        fails_mean.append((col, mean))
        check1_ok = False
    if not s_ok:
        fails_std.append((col, std))
        check1_ok = False

print()
if check1_ok:
    print(f"  ✓ CHECK 1 APROBADO — todas las {len(num_cols)} columnas: mean≈0, std≈1 (tol {TOL})")
else:
    print(f"  ✗ CHECK 1 FALLIDO:")
    if fails_mean: print(f"    mean fuera de tol: {fails_mean}")
    if fails_std:  print(f"    std  fuera de tol: {fails_std}")

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 2 — test_norm: mean/std NO son ≈0/1 (confirmar no-refit)
# ═══════════════════════════════════════════════════════════════════════════
print(f"\n{SEP}")
print("CHECK 2 — test_norm: mean/std reales (NO deben ser ≈0/1 — confirma no-refit)")
print(SEP)

sample_cols = list(num_cols[:4])  # primeras 4 con params
col_vals_test = defaultdict(list)
for row in test_nrm:
    for col in sample_cols:
        v = row.get(col, "").strip()
        if is_numeric_str(v):
            col_vals_test[col].append(float(v))

print(f"  {'Columna':<52} {'N':>5} {'mean':>12} {'std':>12}  Comentario")
print(f"  {'-'*52} {'-'*5} {'-'*12} {'-'*12}  {'-'*30}")

check2_ok = True
for col in sample_cols:
    vals = col_vals_test[col]
    n = len(vals)
    if n < 2:
        print(f"  {col:<52} {n:>5} {'N/A':>12} {'N/A':>12}  (pocos datos)")
        continue
    mean = sum(vals) / n
    std  = math.sqrt(sum((v - mean)**2 for v in vals) / n)
    note = "OK (distinto de 0/1 → no refit)" if abs(mean) > TOL or abs(std - 1.0) > TOL else "SOSPECHOSO (≈0/1)"
    if "SOSPECHOSO" in note:
        check2_ok = False
    print(f"  {col:<52} {n:>5} {mean:>12.6f} {std:>12.6f}  {note}")

print()
if check2_ok:
    print("  ✓ CHECK 2 APROBADO — test NO tiene mean≈0/std≈1 → params no fueron refiteados sobre test")
else:
    print("  ✗ CHECK 2 ATENCIÓN — alguna columna da ≈0/1 en test (puede ser coincidencia si distribuciones son similares)")

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 3 — Celdas vacías siguen vacías
# ═══════════════════════════════════════════════════════════════════════════
print(f"\n{SEP}")
print("CHECK 3 — Celdas vacías en original → siguen vacías en normalizado")
print(SEP)

check3_ok = True
violations = []

for i, (orig_row, norm_row) in enumerate(zip(train_orig, train_nrm), start=1):
    for col in num_cols:
        orig_v = orig_row.get(col, "").strip()
        norm_v = norm_row.get(col, "").strip()
        if orig_v == "":
            # debe seguir vacía
            if norm_v != "":
                violations.append((i, col, norm_v))
                check3_ok = False

# También test
for i, (orig_row, norm_row) in enumerate(zip(test_orig, test_nrm), start=1):
    for col in num_cols:
        orig_v = orig_row.get(col, "").strip()
        norm_v = norm_row.get(col, "").strip()
        if orig_v == "":
            if norm_v != "":
                violations.append((f"test-{i}", col, norm_v))
                check3_ok = False

if check3_ok:
    print(f"  ✓ CHECK 3 APROBADO — ninguna celda vacía fue rellenada en train ni en test")
else:
    print(f"  ✗ CHECK 3 FALLIDO — {len(violations)} violaciones (máx 5 mostradas):")
    for v in violations[:5]:
        print(f"    fila={v[0]}, col={v[1]}, valor_inventado='{v[2]}'")

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 4 — Categóricas y targets IDÉNTICOS
# ═══════════════════════════════════════════════════════════════════════════
print(f"\n{SEP}")
print("CHECK 4 — Columnas *_kind y targets: IDÉNTICOS entre original y normalizado")
print(SEP)

check4_ok = True
cat_tgt_cols = cat_cols + tgt_cols

for col in cat_tgt_cols:
    diffs = 0
    for i, (orig_row, norm_row) in enumerate(zip(train_orig, train_nrm), start=1):
        o = orig_row.get(col, "")
        n = norm_row.get(col, "")
        if o != n:
            diffs += 1
            if diffs == 1:
                print(f"  ✗ {col}: diferencia en fila {i}: orig='{o}' vs norm='{n}'")
    if diffs == 0:
        print(f"  ✓ {col}: idéntico ({len(train_orig)} filas)")
    else:
        print(f"  ✗ {col}: {diffs} diferencias")
        check4_ok = False

print()
if check4_ok:
    print(f"  ✓ CHECK 4 APROBADO — {len(cat_tgt_cols)} columnas ({len(cat_cols)} cat + {len(tgt_cols)} targets) idénticas")
else:
    print("  ✗ CHECK 4 FALLIDO — hay diferencias en categóricas/targets")

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 5 — 2 filas reales antes/después (train fila 1 y fila 50)
# ═══════════════════════════════════════════════════════════════════════════
print(f"\n{SEP}")
print("CHECK 5 — 2 filas reales antes/después (train, filas 1 y 50)")
print(SEP)

for idx in [0, 49]:
    if idx >= len(train_orig):
        continue
    orig_row = train_orig[idx]
    norm_row = train_nrm[idx]
    print(f"\n  --- Fila {idx+1} ---")
    print(f"  {'Columna':<50} {'ORIGINAL':>20} {'NORMALIZADO':>20}")
    print(f"  {'-'*50} {'-'*20} {'-'*20}")
    # Mostrar primeras 12 columnas numéricas + 4 categóricas + 4 targets
    show_cols = num_cols[:12] + cat_cols[:4] + tgt_cols[:4]
    for col in show_cols:
        o = orig_row.get(col, "")
        n = norm_row.get(col, "")
        flag = ""
        if o and is_numeric_str(o) and n and is_numeric_str(n):
            exp_n = (float(o) - params[col]["mean"]) / params[col]["std"] if col in params else None
            if exp_n is not None and abs(float(n) - exp_n) > 0.0001:
                flag = " ← DISCREPANCIA"
        print(f"  {col:<50} {str(o):>20} {str(n):>20}{flag}")

# ═══════════════════════════════════════════════════════════════════════════
# RESUMEN FINAL
# ═══════════════════════════════════════════════════════════════════════════
print(f"\n{SEP}")
print("RESUMEN FASE 3 — Validación completa")
print(SEP)
results = {
    "CHECK 1 — train mean≈0/std≈1": check1_ok,
    "CHECK 2 — test no refit":      check2_ok,
    "CHECK 3 — vacias preservadas": check3_ok,
    "CHECK 4 — cat/target idem":    check4_ok,
}
all_ok = all(results.values())
for name, ok in results.items():
    status = "✓ APROBADO" if ok else "✗ FALLIDO"
    print(f"  {status}  {name}")

print()
if all_ok:
    print("  ══ FASE 3 COMPLETA Y VALIDADA ══")
else:
    print("  !! HAY CHECKS FALLIDOS — revisar antes de cerrar Fase 3")
print()
