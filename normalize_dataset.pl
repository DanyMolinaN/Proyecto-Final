#!/usr/bin/perl

# =============================================================================
# normalize_dataset.pl — Fase 3: Normalizacion z-score de features
# =============================================================================
# 1. Calcula params (mean/std) SOLO sobre train_features.csv
# 2. Guarda params en output/normalization_params.json
# 3. Aplica normalizacion a train (fit+transform) -> train_features_normalized.csv
# 4. Aplica MISMOS params a test  (solo transform) -> test_features_normalized.csv
#
# Columnas categoricas (*_kind), targets (trails_*) y vacias: copiadas tal cual.
# Celdas vacias en columnas normalizables: permanecen vacias en salida.
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;

use Market::Concepts::DSVWAP::Normalizer;
use File::Spec;

my $OUT_DIR   = File::Spec->catfile($Bin, 'output');
my $TRAIN_CSV = File::Spec->catfile($OUT_DIR, 'train_features.csv');
my $TEST_CSV  = File::Spec->catfile($OUT_DIR, 'test_features.csv');
my $PARAMS_JSON = File::Spec->catfile($OUT_DIR, 'normalization_params.json');
my $TRAIN_NORM  = File::Spec->catfile($OUT_DIR, 'train_features_normalized.csv');
my $TEST_NORM   = File::Spec->catfile($OUT_DIR, 'test_features_normalized.csv');

my $sep = "=" x 60;

# ---- PASO 1: Calcular params sobre TRAIN ----
print "\n$sep\n";
print "PASO 1: Calculando params z-score sobre train\n";
print "$sep\n";

die "No se encuentra $TRAIN_CSV\n" unless -f $TRAIN_CSV;
my $params = Market::Concepts::DSVWAP::Normalizer->compute_params($TRAIN_CSV);

printf "  Columnas con params calculados: %d\n", scalar keys %$params;
print  "  (Columnas con 0 valores o std=0 reciben warnings y se excluyen)\n";

# ---- PASO 2: Guardar JSON ----
print "\n$sep\n";
print "PASO 2: Guardando normalization_params.json\n";
print "$sep\n";

Market::Concepts::DSVWAP::Normalizer->save_params($params, $PARAMS_JSON);
printf "  Guardado: %s\n", $PARAMS_JSON;

# Verificar que el JSON se guardó correctamente
my $reloaded = Market::Concepts::DSVWAP::Normalizer->load_params($PARAMS_JSON);
printf "  Verificacion: %d columnas en JSON (debe coincidir con arriba)\n",
    scalar keys %$reloaded;
die "ERROR: params guardados != cargados\n"
    unless scalar keys %$params == scalar keys %$reloaded;
print  "  OK: JSON correcto.\n";

# ---- PASO 3: Aplicar normalizacion a TRAIN (fit+transform) ----
print "\n$sep\n";
print "PASO 3: Normalizando train_features.csv\n";
print "$sep\n";

my $n_train = Market::Concepts::DSVWAP::Normalizer->apply_normalization(
    $TRAIN_CSV, $params, $TRAIN_NORM
);
printf "  Filas normalizadas: %d\n", $n_train;
printf "  Salida: %s\n", $TRAIN_NORM;

# ---- PASO 4: Aplicar MISMOS params a TEST (solo transform) ----
print "\n$sep\n";
print "PASO 4: Normalizando test_features.csv (mismos params de train)\n";
print "$sep\n";

die "No se encuentra $TEST_CSV\n" unless -f $TEST_CSV;
my $n_test = Market::Concepts::DSVWAP::Normalizer->apply_normalization(
    $TEST_CSV, $params, $TEST_NORM   # <-- MISMOS params, sin refit
);
printf "  Filas normalizadas: %d\n", $n_test;
printf "  Salida: %s\n", $TEST_NORM;

print "\n$sep\n";
printf "FASE 3 NORMALIZACION COMPLETA\n";
print "$sep\n";
printf "  train: %d filas -> %s\n", $n_train, $TRAIN_NORM;
printf "  test : %d filas -> %s\n", $n_test,  $TEST_NORM;
printf "  JSON : %s\n", $PARAMS_JSON;
print  "  Params calculados SOLO sobre train. Test: solo transform, nunca refit.\n";
print "\n";
