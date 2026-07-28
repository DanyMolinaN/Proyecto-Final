# Fase 5 — Evaluación Final: Ghost Trail Prediction

**Proyecto Final — Motor Financiero 5**  
Sistema de predicción de Ghost Trails (divergencias ancla → extensión de precio)

---

## 1. Selección Final de Modelo por Horizonte

La selección se basa en el **MAE de validación temporal** (20% interno de train),
**no** en el test set. El test set se usa únicamente para reportar el resultado final honesto.

| Horizonte | Modelo Seleccionado | Val MAE | Test MAE | Justificación |
|-----------|---------------------|---------|----------|---------------|
| **trails_3m** | `baseline_zero` | 0.0167 | 0.0399 | Mínimo MAE. Clase dominante es 0 (>97%). Modelos complejos introducen falsos positivos costosos. |
| **trails_5m** | `baseline_zero` | 0.0367 | 0.0623 | Mínimo MAE. Clase dominante es 0 (>97%). Modelos complejos introducen falsos positivos costosos. |
| **trails_10m** | `baseline_zero` | 0.0933 | 0.1147 | Mínimo MAE. Clase dominante es 0 (>97%). Modelos complejos introducen falsos positivos costosos. |
| **trails_15m** | `baseline_zero` | 0.1733 | 0.2045 | Mínimo MAE. Clase dominante es 0 (>97%). Modelos complejos introducen falsos positivos costosos. |

---

## 2. Tabla Comparativa Completa (Validación y Test)

### 2a. MAE en Validación Interna (20% de train, base de selección)

| Horizonte | Baseline A (0) | Baseline B (media) | Ridge Puro | Hurdle Lineal | MLP Multi-task |
|-----------|---------------|-------------------|------------|---------------|----------------|
| **trails_3m** | 0.0167 | 0.0538 | 0.1036 | 0.0167 | N/A\* |
| **trails_5m** | 0.0367 | 0.0901 | 0.1381 | 0.0400 | N/A\* |
| **trails_10m** | 0.0933 | 0.1985 | 0.2275 | 0.1000 | N/A\* |
| **trails_15m** | 0.1733 | 0.3558 | 0.3698 | 0.1800 | N/A\* |

> \* MLP entrenado sobre 100% de train; val_mae no disponible. Excluido de selección.

### 2b. MAE / RMSE en Test Set (N=401, solo para reporte)

| Horizonte | Baseline A (0) | Baseline B (media) | Ridge Puro | Hurdle Lineal | MLP Multi-task |
|-----------|---------------|-------------------|------------|---------------|----------------|
| **trails_3m** MAE | 0.0399 | 0.0753 | 0.0528 | 0.0399 | 0.0474 |
| **trails_5m** MAE | 0.0623 | 0.1135 | 0.0773 | 0.0623 | 0.0848 |
| **trails_10m** MAE | 0.1147 | 0.2174 | 0.1880 | 0.1147 | 0.3242 |
| **trails_15m** MAE | 0.2045 | 0.3803 | 0.3638 | 0.2045 | 0.4264 |

| Horizonte | Baseline A (0) | Baseline B (media) | Ridge Puro | Hurdle Lineal | MLP Multi-task |
|-----------|---------------|-------------------|------------|---------------|----------------|
| **trails_3m** RMSE | 0.1998 | 0.1957 | 0.2009 | 0.1998 | 0.2177 |
| **trails_5m** RMSE | 0.3119 | 0.3056 | 0.3120 | 0.3119 | 0.3601 |
| **trails_10m** RMSE | 0.5951 | 0.5839 | 0.5961 | 0.5951 | 0.8621 |
| **trails_15m** RMSE | 0.9099 | 0.8867 | 0.9249 | 0.9099 | 1.1088 |

---

## 3. Diagnóstico de Señal

### 3a. Top 10 Correlaciones (Pearson) Feature vs Target — train

#### trails_3m — Correlación Continua (vs y real)

| # | Feature | r (Pearson) |
|---|---------|-------------|
| 1 | `structure_below_pip_1h` | -0.1026 |
| 2 | `fib_618_pip_1h` | +0.0885 |
| 3 | `fib_500_pip_1h` | +0.0883 |
| 4 | `fib_236_pip_1h` | +0.0872 |
| 5 | `fib_382_pip_1h` | +0.0868 |
| 6 | `fib_0_pip_1h` | +0.0860 |
| 7 | `fib_786_pip_1h` | +0.0834 |
| 8 | `ob_above_pip_10m_missing` | +0.0808 |
| 9 | `ob_above_thickness_pip_10m_missing` | +0.0808 |
| 10 | `vp_val_pip_10m` | +0.0779 |

#### trails_3m — Correlación Binaria (vs y>0)

| # | Feature | r (Pearson) |
|---|---------|-------------|
| 1 | `structure_below_pip_1h` | -0.0862 |
| 2 | `fib_0_pip_1h` | +0.0807 |
| 3 | `fib_618_pip_1h` | +0.0801 |
| 4 | `fib_236_pip_1h` | +0.0800 |
| 5 | `fib_500_pip_1h` | +0.0790 |
| 6 | `fib_382_pip_1h` | +0.0775 |
| 7 | `fib_786_pip_1h` | +0.0765 |
| 8 | `vwap_band1_thickness_pip_1m` | -0.0735 |
| 9 | `vwap_band2_thickness_pip_1m` | -0.0735 |
| 10 | `vp_va_thickness_pip_1m` | -0.0728 |

#### trails_5m — Correlación Continua (vs y real)

| # | Feature | r (Pearson) |
|---|---------|-------------|
| 1 | `ob_above_pip_10m_missing` | +0.0992 |
| 2 | `ob_above_thickness_pip_10m_missing` | +0.0992 |
| 3 | `structure_below_pip_1h` | -0.0992 |
| 4 | `fib_236_pip_1h` | +0.0859 |
| 5 | `fib_0_pip_1h` | +0.0854 |
| 6 | `fib_382_pip_1h` | +0.0834 |
| 7 | `fib_500_pip_1h` | +0.0833 |
| 8 | `fib_618_pip_1h` | +0.0821 |
| 9 | `vp_val_pip_10m` | +0.0803 |
| 10 | `fib_786_pip_1h` | +0.0752 |

#### trails_5m — Correlación Binaria (vs y>0)

| # | Feature | r (Pearson) |
|---|---------|-------------|
| 1 | `fib_618_pip_1h` | +0.0937 |
| 2 | `fib_236_pip_1h` | +0.0936 |
| 3 | `fib_500_pip_1h` | +0.0934 |
| 4 | `fib_0_pip_1h` | +0.0922 |
| 5 | `fib_382_pip_1h` | +0.0918 |
| 6 | `ob_above_pip_10m_missing` | +0.0908 |
| 7 | `ob_above_thickness_pip_10m_missing` | +0.0908 |
| 8 | `fib_786_pip_1h` | +0.0880 |
| 9 | `structure_below_pip_1h` | -0.0851 |
| 10 | `vp_val_pip_10m` | +0.0786 |

#### trails_10m — Correlación Continua (vs y real)

| # | Feature | r (Pearson) |
|---|---------|-------------|
| 1 | `structure_below_pip_1h` | -0.1058 |
| 2 | `ob_below_pip_1h_missing` | +0.0800 |
| 3 | `ob_below_thickness_pip_1h_missing` | +0.0800 |
| 4 | `fib_236_pip_1h` | +0.0799 |
| 5 | `fib_0_pip_1h` | +0.0789 |
| 6 | `fib_382_pip_1h` | +0.0768 |
| 7 | `fib_500_pip_1h` | +0.0750 |
| 8 | `fib_618_pip_1h` | +0.0730 |
| 9 | `vp_va_thickness_pip_1h` | -0.0724 |
| 10 | `fib_0_pip_1h_missing` | +0.0715 |

#### trails_10m — Correlación Binaria (vs y>0)

| # | Feature | r (Pearson) |
|---|---------|-------------|
| 1 | `structure_below_pip_1h` | -0.1055 |
| 2 | `fib_236_pip_1h` | +0.0887 |
| 3 | `fib_0_pip_1h` | +0.0882 |
| 4 | `fib_382_pip_1h` | +0.0856 |
| 5 | `fib_500_pip_1h` | +0.0849 |
| 6 | `vp_val_pip_10m` | +0.0849 |
| 7 | `fib_618_pip_1h` | +0.0833 |
| 8 | `ob_below_pip_1h` | +0.0817 |
| 9 | `fib_786_pip_1h` | +0.0738 |
| 10 | `vwap_l1_pip_10m` | +0.0724 |

#### trails_15m — Correlación Continua (vs y real)

| # | Feature | r (Pearson) |
|---|---------|-------------|
| 1 | `ob_below_pip_1h_missing` | +0.1530 |
| 2 | `ob_below_thickness_pip_1h_missing` | +0.1530 |
| 3 | `structure_below_pip_1h_missing` | +0.1289 |
| 4 | `fib_0_pip_1h_missing` | +0.1061 |
| 5 | `fib_1000_pip_1h_missing` | +0.1061 |
| 6 | `fib_236_pip_1h_missing` | +0.1061 |
| 7 | `fib_382_pip_1h_missing` | +0.1061 |
| 8 | `fib_500_pip_1h_missing` | +0.1061 |
| 9 | `fib_618_pip_1h_missing` | +0.1061 |
| 10 | `fib_786_pip_1h_missing` | +0.1061 |

#### trails_15m — Correlación Binaria (vs y>0)

| # | Feature | r (Pearson) |
|---|---------|-------------|
| 1 | `ob_below_pip_1h_missing` | +0.0933 |
| 2 | `ob_below_thickness_pip_1h_missing` | +0.0933 |
| 3 | `vp_va_thickness_pip_1h` | -0.0826 |
| 4 | `mtf_pwl_pip_1m` | +0.0806 |
| 5 | `mtf_pwl_pip_10m` | +0.0806 |
| 6 | `mtf_pwl_pip_1h` | +0.0806 |
| 7 | `structure_below_pip_1h` | -0.0802 |
| 8 | `fib_0_pip_1m` | -0.0772 |
| 9 | `fvg_below_pip_1m` | -0.0759 |
| 10 | `vwap_band1_thickness_pip_1h` | -0.0759 |

### 3b. Top 10 Coeficientes Ridge |β| (modelo final 100% train)

#### trails_3m

| # | Feature | β |
|---|---------|---|
| 1 | `intercept` | +0.028773 |
| 2 | `structure_below_pip_1h` | -0.027204 |
| 3 | `ob_above_pip_10m_missing` | +0.018450 |
| 4 | `ob_above_thickness_pip_10m_missing` | +0.018450 |
| 5 | `structure_below_pip_10m` | +0.017545 |
| 6 | `ob_below_pip_10m` | +0.017320 |
| 7 | `vwap_band1_thickness_pip_10m` | -0.015750 |
| 8 | `vwap_band2_thickness_pip_10m` | -0.015750 |
| 9 | `vp_val_pip_1h` | +0.014431 |
| 10 | `vp_poc_pip_1h` | -0.014010 |

#### trails_5m

| # | Feature | β |
|---|---------|---|
| 1 | `intercept` | +0.038302 |
| 2 | `structure_below_pip_1h` | -0.036038 |
| 3 | `ob_above_pip_10m_missing` | +0.031741 |
| 4 | `ob_above_thickness_pip_10m_missing` | +0.031741 |
| 5 | `fvg_below_size_pip_1m` | +0.024111 |
| 6 | `vp_val_pip_10m` | +0.023920 |
| 7 | `structure_below_pip_10m` | +0.022862 |
| 8 | `vwap_band1_thickness_pip_10m` | -0.021864 |
| 9 | `vwap_band2_thickness_pip_10m` | -0.021864 |
| 10 | `vp_poc_pip_1h` | -0.021620 |

#### trails_10m

| # | Feature | β |
|---|---------|---|
| 1 | `intercept` | +0.120748 |
| 2 | `fvg_below_size_pip_1m` | +0.070952 |
| 3 | `vp_vah_pip_10m` | -0.054732 |
| 4 | `structure_below_pip_1h` | -0.054241 |
| 5 | `vp_va_thickness_pip_10m` | +0.051433 |
| 6 | `fvg_above_pip_10m` | -0.048773 |
| 7 | `atr_1m` | +0.046545 |
| 8 | `vp_val_pip_10m` | +0.046128 |
| 9 | `fvg_below_pip_1m` | -0.043957 |
| 10 | `structure_above_kind_1h_BOS` | -0.041962 |

#### trails_15m

| # | Feature | β |
|---|---------|---|
| 1 | `intercept` | +0.242992 |
| 2 | `fvg_below_size_pip_1h_missing` | +0.084454 |
| 3 | `fvg_below_pip_1h_missing` | +0.084454 |
| 4 | `structure_above_kind_1h_BOS` | -0.078232 |
| 5 | `fvg_below_pip_1m` | -0.074621 |
| 6 | `structure_above_kind_1h_CHoCH` | +0.073829 |
| 7 | `fib_0_pip_1m` | -0.070064 |
| 8 | `fvg_below_size_pip_1m` | +0.069864 |
| 9 | `vp_vah_pip_10m` | -0.069258 |
| 10 | `fvg_above_pip_10m` | -0.065896 |

### 3c. Frecuencia de Apariciones vs Rastros

| Horizonte | Rastros (trail>0) | Sin Rastro | Total Anclas | % Ceros |
|-----------|-------------------|------------|--------------|----------|
| **trails_3m** | 39 | 1458 | 1497 | 97.4% |
| **trails_5m** | 49 | 1448 | 1497 | 96.7% |
| **trails_10m** | 85 | 1412 | 1497 | 94.3% |
| **trails_15m** | 130 | 1367 | 1497 | 91.3% |

**Apariciones totales registradas:** 1898 (train: 1497, test: 401)

**Distribución de gaps entre apariciones de ancla consecutivas (velas de 1m):**

| Métrica | Valor |
|---------|-------|
| Span total (anchor_index) | 121 .. 88668 (88,547 velas) |
| Apariciones / total velas | **2.14%** |
| Gap mínimo | 1 vela |
| Gap mediana | **37 velas** |
| Gap media | **47.8 velas** |
| Gap máximo | 294 velas |
| Gaps ≤ 10 velas | 278 apariciones (15.0%) |
| Gaps > 100 velas | 205 apariciones (11.1%) |
| Gaps back-to-back (=1) | 56 apariciones (3.0%) |

**Conclusión con datos:** Las apariciones de ancla (divergencias) representan el **2.14%** de
las velas del dataset, con una mediana de 37 velas entre cambios de ancla. No son
eventos raros — ocurren cada ~38 velas de promedio. La rareza está completamente en
los **rastros** (trail > 0): solo 2.6–8.7% de las apariciones generan un rastro
observable en la ventana de 3–15 minutos post-ancla.

**Explicación estructural del 91–97% de ceros:**

Un *Ghost Trail* ocurre cuando el precio pone un nuevo extremo (`x_last == index`)
en las velas que siguen a una aparición (cambio de ancla de divergencia). Dado que
la divergencia **es** por definición un punto de reversión o agotamiento del impulso,
el escenario estadísticamente esperado tras una divergencia es la *reversión*, no la
*continuación*. Si el precio revierte, no produce un nuevo extremo en la dirección
del impulso previo → el trail es 0.

Los trails > 0 ocurren solo cuando la divergencia **falla**: el precio ignora la
divergencia y continúa empujando. Esto es estructuralmente infrecuente (< 9% incluso
en la ventana más amplia de 15 min), y su predicción requeriría señales de momentum
intra-vela o datos de flujo de órdenes que no están presentes en el snapshot
estático de liquidez capturado. Esta explicación está confirmada por los datos:
la escasez de rastros **no** se debe a que las apariciones sean raras, sino a que
la reversión es el resultado esperado de una divergencia bien formada.

---

## 4. Narrativa de Investigación — Resumen Ejecutivo

Para predecir los *Ghost Trails* (extensiones de precio tras una divergencia de
ancla), se construyó un snapshot de liquidez de 169 variables (distancias a VWAP,
perfiles de volumen, Order Blocks, FVG, Fibonacci, niveles MTF) sobre 1498 anclas
de entrenamiento y 401 de test, con split temporal estricto.

Se evaluaron cinco enfoques:

| Enfoque | Descripción | Resultado |
|---------|-------------|-----------|
| **Baseline A (0 constante)** | Predice siempre 0 | Mejor o igual en todos los horizontes |
| **Baseline B (media train)** | Predice la media del target | Peor que A en MAE (infla error en ceros) |
| **Ridge Puro** | Regresión Ridge multi-output, λ∈{0.01…100} | No supera Baseline A en ningún horizonte |
| **Hurdle Lineal** | Ridge clasificador + Ridge regresor en cascada | Introduce falsos positivos; peor que A |
| **MLP Multi-task** | Red feedforward de 2 capas, 4 salidas | Overfit severo; peor que A en test |

**Hallazgo principal:** Ningún modelo de ML supera la estrategia trivial de predecir cero.
Las correlaciones máximas entre features y targets son r ≈ 0.10–0.15, prácticamente
ruido plano. Los coeficientes Ridge están dominados por el intercepto y por flags
de ausencia de niveles estructurales (columns `_missing`), no por mediciones de distancia.

**Causa estructural:** Las divergencias son señales de agotamiento del impulso; la
continuación del precio (trail > 0) es el evento excepcional, no la regla. El modelo
estadísticamente óptimo es predecir "no habrá trail", que minimiza el error absoluto
dada la distribución masivamente sesgada del target.

**Decisión de producción (Fase 6):** Se adopta `baseline_zero` para los cuatro
horizontes. Esta decisión elimina latencia y complejidad sin sacrificar precisión, y
es la selección honesta basada en validación temporal interna. Cualquier sistema que
intente mejorar este baseline necesitaría datos de flujo de órdenes intra-vela o
señales de momentum no disponibles en el snapshot estático actual.

---

## 5. Empaquetado para Fase 6

### Artefactos generados

| Artefacto | Ubicación | Uso en Fase 6 |
|-----------|-----------|---------------|
| `model_selection.json` | `output/` | Fuente de verdad: qué enfoque usar por horizonte |
| `models.json` | `output/` | Pesos Ridge (disponibles si fuese necesario) |

### Protocolo de carga para Fase 6

Para cada horizonte, leer `model_selection.json`:

- Si `approach == "baseline_zero"`: predecir **0** directamente. **No cargar ningún artefacto de modelo.**
- Si `approach == "ridge_pure"`: cargar `models.json`, vector `beta[horizonte]`, y calcular `dot(x, beta)`.
- Si `approach == "hurdle_linear"`: cargar `models.json` para Ridge regresor + reconstruir clasificador.

**Con la selección actual (todos los horizontes = `baseline_zero`), Fase 6 no necesita
cargar ningún modelo ML.** La predicción es trivialmente `predict(x) = 0` para todo x,
en los cuatro horizontes. Esto garantiza latencia de predicción < 1ms y cero dependencias
de artefactos en producción.

---

*Generado automáticamente por `fase5_diagnostico.pl` — Fase 5 completa.*
