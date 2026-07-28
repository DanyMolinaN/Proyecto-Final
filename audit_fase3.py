#!/usr/bin/env python3
"""
audit_fase3_v2.py — Paso 0 corregido: Auditoria de columnas de train_features.csv
Clasifica correctamente columnas categoricas (*_kind), numericas y targets.
NO modifica ningun archivo.
"""
import csv, math
from collections import defaultdict

CSV_PATH = "output/train_features.csv"

TARGETS = {"trails_3m", "trails_5m", "trails_10m", "trails_15m"}
META    = {"anchor_index"}

def classify(col):
    if col in TARGETS: return "TARGET"
    if col in META:    return "META"
    # Categoricas: las que contienen 'kind' en el nombre (valores string)
    if "kind" in col:  return "CATEGORICAL"
    return "NUMERIC"

# ---- Leer CSV ----
with open(CSV_PATH, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    headers = reader.fieldnames
    rows = list(reader)

n_rows = len(rows)
targets_cols     = [c for c in headers if classify(c) == "TARGET"]
categorical_cols = [c for c in headers if classify(c) == "CATEGORICAL"]
numeric_cols     = [c for c in headers if classify(c) == "NUMERIC"]
meta_cols        = [c for c in headers if classify(c) == "META"]

SEP = "=" * 72

# ---- Recopilar valores numericos ----
col_values = defaultdict(list)
col_empty  = defaultdict(int)

for row in rows:
    for col in numeric_cols:
        v = row.get(col, "")
        if v is None or str(v).strip() == "":
            col_empty[col] += 1
        else:
            try:
                col_values[col].append(float(v))
            except ValueError:
                col_empty[col] += 1

# ---- Calcular stats ----
col_stats = {}
for col in numeric_cols:
    vals = col_values[col]
    n_present = len(vals)
    n_empty   = col_empty.get(col, 0)
    if n_present == 0:
        col_stats[col] = dict(mean=None, std=None, n_present=0, n_empty=n_empty)
        continue
    mean = sum(vals) / n_present
    std  = math.sqrt(sum((v - mean)**2 for v in vals) / n_present)
    col_stats[col] = dict(mean=mean, std=std, n_present=n_present, n_empty=n_empty)

# =============================================================================
print(f"\nTotal filas  : {n_rows}")
print(f"Total columnas: {len(headers)}")
print()

# --- GRUPO A: TARGETS ---
print(SEP)
print("GRUPO A — TARGETS (nunca se normalizan)  [4 columnas]")
print(SEP)
for c in targets_cols:
    print(f"  col {headers.index(c)+1:3d}: {c}")
print()

# --- GRUPO B: CATEGORICAS ---
print(SEP)
print(f"GRUPO B — CATEGORICAS (*_kind, se copian tal cual)  [{len(categorical_cols)} columnas]")
print(SEP)
print(f"  {'Columna':<45} {'Vacias':>7}  {'%':>6}  Valores únicos")
print(f"  {'-'*45} {'-'*7}  {'-'*6}  {'-'*30}")
for c in categorical_cols:
    vals_all  = [row.get(c,"").strip() for row in rows]
    empty_cnt = sum(1 for v in vals_all if v == "")
    unique    = sorted(set(v for v in vals_all if v))
    pct = 100.0 * empty_cnt / n_rows
    print(f"  {c:<45} {empty_cnt:>7}  {pct:>5.1f}%  {unique}")
print()

# --- GRUPO C: NUMERICAS ---
print(SEP)
print(f"GRUPO C — NUMERICAS A NORMALIZAR  [{len(numeric_cols)} columnas]")
print(SEP)
print(f"  {'Columna':<50} {'Pres':>5} {'Vac':>5} {'%Vac':>6}  {'Mean':>12}  {'Std':>12}  Nota")
print(f"  {'-'*50} {'-'*5} {'-'*5} {'-'*6}  {'-'*12}  {'-'*12}  {'-'*20}")

zero_std_cols  = []
all_empty_cols = []

for col in numeric_cols:
    s   = col_stats[col]
    pct = 100.0 * s["n_empty"] / n_rows
    mean_s = f"{s['mean']:12.4f}" if s["mean"] is not None else "         N/A"
    std_s  = f"{s['std']:12.4f}"  if s["std"]  is not None else "         N/A"
    note = ""
    if s["n_present"] == 0:
        note = "*** TODO VACIO"
        all_empty_cols.append(col)
    elif s["std"] == 0:
        note = "*** STD=0"
        zero_std_cols.append(col)
    elif pct > 10:
        note = f"sparse {pct:.0f}%"
    print(f"  {col:<50} {s['n_present']:>5} {s['n_empty']:>5} {pct:>5.1f}%  {mean_s}  {std_s}  {note}")

print()
print(SEP)
print("RESUMEN CRITICO — Paso 0")
print(SEP)
print(f"  Targets              : {len(targets_cols):3d} columnas")
print(f"  Categoricas (*_kind) : {len(categorical_cols):3d} columnas")
print(f"  Numericas            : {len(numeric_cols):3d} columnas")
print(f"  Meta (anchor_index)  : {len(meta_cols):3d} columnas")
print(f"  TOTAL                : {len(targets_cols)+len(categorical_cols)+len(numeric_cols)+len(meta_cols):3d} columnas")
print()

if zero_std_cols:
    print(f"  !!! ALERTA — Columnas con std=0 — se excluiran de normalizacion:")
    for c in zero_std_cols: print(f"      {c}")
else:
    print("  OK: Ningun std=0 — sin riesgo de division por cero.")

if all_empty_cols:
    print(f"\n  WARN: Columnas 100% vacias en train ({len(all_empty_cols)}):")
    for c in all_empty_cols: print(f"      {c}")
    print("  => mean/std = N/A. Se copiaran tal cual (sin normalizar).")
else:
    print("  OK: Todas las columnas numericas tienen al menos un valor.")

aptas = sum(1 for s in col_stats.values() if s["mean"] is not None and s["std"] and s["std"] != 0)
print(f"\n  Columnas aptas para z-score: {aptas} / {len(numeric_cols)}")
print(f"  (Las {len(numeric_cols)-aptas} restantes son 100% vacias en train => se copian sin normalizar)")
print()

# Nota sobre structure_*_pip: tienen valores negativos (below ref_price) — normal
below_pip_cols = [c for c in numeric_cols if "_below_pip_" in c]
print(f"  Nota: {len(below_pip_cols)} columnas *_below_pip tienen medias negativas —")
print(f"  esto es correcto (distancia con signo: below = negativo)")
print()
print("Auditoria completa. No se modifico ningun archivo.")
