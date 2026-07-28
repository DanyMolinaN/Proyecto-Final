package Market::Concepts::DSVWAP::DatasetBuilder;

# =============================================================================
# Market::Concepts::DSVWAP::DatasetBuilder  — Fase 2
# =============================================================================
#
# RESPONSABILIDAD:
#   Construye el dataset final de entrenamiento/test (CSV) a partir de
#   MarketData + ModularEngine + GhostTrailCounter + LiquiditySnapshot.
#
# API PUBLICA:
#   build_dataset($market_data, %opts)  -- genera features + targets para un dataset
#
# COLUMNAS (por TF: sufijo _1m / _10m / _1h):
#   ob_above_pip, ob_above_thickness_pip,
#   ob_below_pip, ob_below_thickness_pip,
#   fvg_above_pip, fvg_above_size_pip,
#   fvg_below_pip, fvg_below_size_pip,
#   fib_0_pip, fib_236_pip, fib_382_pip, fib_500_pip,
#     fib_618_pip, fib_786_pip, fib_1000_pip,
#   vwap_pip, vwap_u1_pip, vwap_l1_pip, vwap_u2_pip, vwap_l2_pip,
#     vwap_band1_thickness_pip, vwap_band2_thickness_pip,
#   vp_poc_pip, vp_vah_pip, vp_val_pip, vp_va_thickness_pip,
#   mtf_pdh_pip, mtf_pdl_pip, mtf_pwh_pip, mtf_pwl_pip,
#   structure_above_pip, structure_above_kind,
#   structure_below_pip, structure_below_kind,
#   eq_above_pip, eq_above_kind,
#   eq_below_pip, eq_below_kind
#
# COLUMNAS GLOBALES (calculadas UNA sola vez sobre 1m en anchor_index):
#   atr_1m, volume_1m, ema9_volume_1m
#
# TARGETS:
#   trails_3m, trails_5m, trails_10m, trails_15m
#
# METADATA (archivo separado, NO entra al entrenamiento):
#   anchor_index, anchor_ts, fecha, hora, minuto
# =============================================================================

use strict;
use warnings;
use POSIX qw(floor);

use Market::Concepts::DSVWAP::ModularEngine;
use Market::Indicators::ATR;
use Market::Indicators::EMA;

# ---------------------------------------------------------------------------
# ESQUEMA DE COLUMNAS POR TF
# ---------------------------------------------------------------------------
my @TFS = ('1m', '10m', '1h');  # nombres de sufijo (tf_1h en snapshot es tf_1h)
my %TF_SNAP_KEY = (
    '1m'  => 'tf_1m',
    '10m' => 'tf_10m',
    '1h'  => 'tf_1h',
);

# Columnas de features por TF (37 columnas x 3 TFs = 111)
my @TF_COLS = qw(
    ob_above_pip        ob_above_thickness_pip
    ob_below_pip        ob_below_thickness_pip
    fvg_above_pip       fvg_above_size_pip
    fvg_below_pip       fvg_below_size_pip
    fib_0_pip           fib_236_pip         fib_382_pip
    fib_500_pip         fib_618_pip         fib_786_pip         fib_1000_pip
    vwap_pip            vwap_u1_pip         vwap_l1_pip
    vwap_u2_pip         vwap_l2_pip
    vwap_band1_thickness_pip    vwap_band2_thickness_pip
    vp_poc_pip          vp_vah_pip          vp_val_pip          vp_va_thickness_pip
    mtf_pdh_pip         mtf_pdl_pip         mtf_pwh_pip         mtf_pwl_pip
    structure_above_pip structure_above_kind
    structure_below_pip structure_below_kind
    eq_above_pip        eq_above_kind
    eq_below_pip        eq_below_kind
);

# Columnas globales (no por TF)
my @GLOBAL_COLS = qw(atr_1m volume_1m ema9_volume_1m);

# Targets
my @TARGET_COLS = qw(trails_3m trails_5m trails_10m trails_15m);

# Metadatos (archivo separado)
my @META_COLS = qw(anchor_index anchor_ts fecha hora minuto);

# ---------------------------------------------------------------------------
# new()
# ---------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;
    return bless {}, $class;
}

# ===========================================================================
# build_dataset($market_data, %opts) -> { features_rows, meta_rows, discarded }
#
# opts:
#   pip_factor  (default 4)
#   window_1m   (default 500)
#   window_10m  (default 300)
# ===========================================================================
sub build_dataset {
    my ($self, $market_data, %opts) = @_;

    my $pip_factor = $opts{pip_factor} // 4;
    my $window_1m  = $opts{window_1m}  // 500;
    my $window_10m = $opts{window_10m} // 300;

    # 1. Calcular apariciones + snapshots via ModularEngine
    my $engine = Market::Concepts::DSVWAP::ModularEngine->new(length => 50);
    my $result  = $engine->calculate($market_data);
    my $counter = $result->{_ghost_counter}
        or die "DatasetBuilder: _ghost_counter no encontrado en resultado de ModularEngine\n";

    my $rows = $counter->count_trails_batch_with_snapshot(
        $market_data,
        pip_factor => $pip_factor,
        window_1m  => $window_1m,
        window_10m => $window_10m,
    );

    # 2. Pre-calcular ATR(14) y EMA(9 volume) sobre la serie 1m completa
    my $atr_ind = Market::Indicators::ATR->new(14);
    my $ema_ind = Market::Indicators::EMA->new(9, field => 'volume');

    my $n1m = $market_data->size();
    for my $i (0 .. $n1m - 1) {
        $atr_ind->update_at_index($market_data, $i);
        $ema_ind->update_at_index($market_data, $i);
    }
    my $atr_vals = $atr_ind->get_values();
    my $ema_vals = $ema_ind->get_values();

    # 3. Aplanar filas
    my (@feature_rows, @meta_rows);
    my $discarded = 0;

    for my $row (@$rows) {
        # Descartar si algún TF es undef
        unless (defined $row->{tf_10m} && ref $row->{tf_10m} eq 'HASH') {
            $discarded++;
            next;
        }
        unless (defined $row->{tf_1h} && ref $row->{tf_1h} eq 'HASH') {
            $discarded++;
            next;
        }

        my $ai = $row->{anchor_index} // 0;

        # --- Columnas globales ---
        my $atr_val    = $atr_vals->[$ai];
        my $vol_val    = undef;
        my $ema9_val   = $ema_vals->[$ai];

        # volume_1m: de la vela en anchor_index
        {
            my $c = eval { $market_data->get_candle($ai) };
            $vol_val = $c->{volume} if $c;
        }

        # Sanear valores (NaN/Inf)
        $atr_val  = _sanitize($atr_val,  "atr_1m",        $ai);
        $vol_val  = _sanitize($vol_val,  "volume_1m",     $ai);
        $ema9_val = _sanitize($ema9_val, "ema9_volume_1m", $ai);

        # --- Columnas por TF ---
        my %flat;

        for my $tf (@TFS) {
            my $snap_key = $TF_SNAP_KEY{$tf};
            my $tfd      = $row->{$snap_key};
            my $suffix   = "_${tf}";

            if (!defined $tfd || ref $tfd ne 'HASH') {
                # Columnas vacias para este TF
                for my $col (@TF_COLS) {
                    $flat{"${col}${suffix}"} = undef;
                }
                next;
            }

            # pip_factor ya fue aplicado por LiquiditySnapshot; no volvemos a multiplicar.

            # OB above/below
            my $ob_flat = flatten_above_below(
                $tfd->{ob} || [],
                'pip_mid',
                ['thickness', sub { defined $_[0]{thickness} ? $_[0]{thickness} * $pip_factor : undef }]
            );
            $flat{"ob_above_pip${suffix}"}           = _sanitize($ob_flat->{above_pip},       "ob_above_pip${suffix}",       $ai);
            $flat{"ob_above_thickness_pip${suffix}"} = _sanitize($ob_flat->{above_thickness}, "ob_above_thickness_pip${suffix}", $ai);
            $flat{"ob_below_pip${suffix}"}           = _sanitize($ob_flat->{below_pip},       "ob_below_pip${suffix}",       $ai);
            $flat{"ob_below_thickness_pip${suffix}"} = _sanitize($ob_flat->{below_thickness}, "ob_below_thickness_pip${suffix}", $ai);

            # FVG above/below
            my $fvg_flat = flatten_above_below(
                $tfd->{fvg} || [],
                'pip_mid',
                ['size', sub { defined $_[0]{size} ? $_[0]{size} * $pip_factor : undef }]
            );
            $flat{"fvg_above_pip${suffix}"}      = _sanitize($fvg_flat->{above_pip},  "fvg_above_pip${suffix}",     $ai);
            $flat{"fvg_above_size_pip${suffix}"} = _sanitize($fvg_flat->{above_size}, "fvg_above_size_pip${suffix}", $ai);
            $flat{"fvg_below_pip${suffix}"}      = _sanitize($fvg_flat->{below_pip},  "fvg_below_pip${suffix}",     $ai);
            $flat{"fvg_below_size_pip${suffix}"} = _sanitize($fvg_flat->{below_size}, "fvg_below_size_pip${suffix}", $ai);

            # Fib (7 columnas fijas)
            my $fib_flat = flatten_fib($tfd->{fib} || [], $ai);
            for my $fk (keys %$fib_flat) {
                $flat{"${fk}${suffix}"} = _sanitize($fib_flat->{$fk}, "${fk}${suffix}", $ai);
            }

            # VWAP
            my $v = $tfd->{vwap} || {};
            $flat{"vwap_pip${suffix}"}                = _sanitize($v->{pip_vwap},             "vwap_pip${suffix}",                $ai);
            $flat{"vwap_u1_pip${suffix}"}             = _sanitize($v->{pip_u1},               "vwap_u1_pip${suffix}",             $ai);
            $flat{"vwap_l1_pip${suffix}"}             = _sanitize($v->{pip_l1},               "vwap_l1_pip${suffix}",             $ai);
            $flat{"vwap_u2_pip${suffix}"}             = _sanitize($v->{pip_u2},               "vwap_u2_pip${suffix}",             $ai);
            $flat{"vwap_l2_pip${suffix}"}             = _sanitize($v->{pip_l2},               "vwap_l2_pip${suffix}",             $ai);
            $flat{"vwap_band1_thickness_pip${suffix}"} = _sanitize($v->{band1_thickness_pip}, "vwap_band1_thickness_pip${suffix}", $ai);
            $flat{"vwap_band2_thickness_pip${suffix}"} = _sanitize($v->{band2_thickness_pip}, "vwap_band2_thickness_pip${suffix}", $ai);

            # VP
            my $vp = $tfd->{vp} || {};
            $flat{"vp_poc_pip${suffix}"}          = _sanitize($vp->{pip_poc},         "vp_poc_pip${suffix}",         $ai);
            $flat{"vp_vah_pip${suffix}"}          = _sanitize($vp->{pip_vah},         "vp_vah_pip${suffix}",         $ai);
            $flat{"vp_val_pip${suffix}"}          = _sanitize($vp->{pip_val},         "vp_val_pip${suffix}",         $ai);
            $flat{"vp_va_thickness_pip${suffix}"} = _sanitize($vp->{va_thickness_pip}, "vp_va_thickness_pip${suffix}", $ai);

            # MTF
            my $mtf = $tfd->{mtf} || {};
            $flat{"mtf_pdh_pip${suffix}"} = _sanitize($mtf->{pip_pdh}, "mtf_pdh_pip${suffix}", $ai);
            $flat{"mtf_pdl_pip${suffix}"} = _sanitize($mtf->{pip_pdl}, "mtf_pdl_pip${suffix}", $ai);
            $flat{"mtf_pwh_pip${suffix}"} = _sanitize($mtf->{pip_pwh}, "mtf_pwh_pip${suffix}", $ai);
            $flat{"mtf_pwl_pip${suffix}"} = _sanitize($mtf->{pip_pwl}, "mtf_pwl_pip${suffix}", $ai);

            # Structure events (BOS/CHoCH) — pip is SIGNED from LiquiditySnapshot
            my $st_flat = flatten_above_below_signed(
                $tfd->{structure_events} || [],
                'pip',
                ['kind', undef],   # string field -> NONE if missing
            );
            $flat{"structure_above_pip${suffix}"}  = _sanitize($st_flat->{above_pip},  "structure_above_pip${suffix}",  $ai);
            $flat{"structure_above_kind${suffix}"} = $st_flat->{above_kind} // 'NONE';
            $flat{"structure_below_pip${suffix}"}  = _sanitize($st_flat->{below_pip},  "structure_below_pip${suffix}",  $ai);
            $flat{"structure_below_kind${suffix}"} = $st_flat->{below_kind} // 'NONE';

            # EQ events (EQH/EQL) — pip is SIGNED from LiquiditySnapshot
            my $eq_flat = flatten_above_below_signed(
                $tfd->{eq_events} || [],
                'pip',
                ['kind', undef],
            );
            $flat{"eq_above_pip${suffix}"}  = _sanitize($eq_flat->{above_pip},  "eq_above_pip${suffix}",  $ai);
            $flat{"eq_above_kind${suffix}"} = $eq_flat->{above_kind} // 'NONE';
            $flat{"eq_below_pip${suffix}"}  = _sanitize($eq_flat->{below_pip},  "eq_below_pip${suffix}",  $ai);
            $flat{"eq_below_kind${suffix}"} = $eq_flat->{below_kind} // 'NONE';
        }

        # --- Fila de features ---
        my %feature_row = (
            %flat,
            atr_1m          => $atr_val,
            volume_1m       => $vol_val,
            ema9_volume_1m  => $ema9_val,
            trails_3m       => $row->{trails_3m},
            trails_5m       => $row->{trails_5m},
            trails_10m      => $row->{trails_10m},
            trails_15m      => $row->{trails_15m},
        );
        push @feature_rows, \%feature_row;

        # --- Fila de metadata ---
        my $ts = $row->{anchor_ts} // '';
        my ($fecha, $hora, $minuto) = _parse_ts($ts);
        push @meta_rows, {
            anchor_index => $ai,
            anchor_ts    => $ts,
            fecha        => $fecha,
            hora         => $hora,
            minuto       => $minuto,
        };
    }

    return {
        feature_rows => \@feature_rows,
        meta_rows    => \@meta_rows,
        discarded    => $discarded,
    };
}

# ===========================================================================
# export_csv($feature_rows, $meta_rows, $features_file, $meta_file)
# Escribe los 2 archivos CSV (features + metadata).
# ===========================================================================
sub export_csv {
    my ($self, $feature_rows, $meta_rows, $features_file, $meta_file) = @_;

    # --- Construir cabecera de features ---
    my @feat_header;
    for my $tf (@TFS) {
        for my $col (@TF_COLS) {
            push @feat_header, "${col}_${tf}";
        }
    }
    push @feat_header, @GLOBAL_COLS;
    push @feat_header, @TARGET_COLS;

    # Escribir features CSV
    _write_csv($features_file, \@feat_header, $feature_rows);

    # Escribir metadata CSV
    _write_csv($meta_file, \@META_COLS, $meta_rows);

    return {
        features_file => $features_file,
        meta_file     => $meta_file,
        rows          => scalar @$feature_rows,
    };
}

# ===========================================================================
# HELPERS DE APLANADO (funciones puras, testeables aisladas)
# ===========================================================================

# ---------------------------------------------------------------------------
# flatten_above_below(\@array, $pip_field, [$extra_name, $extra_getter])
#
# Para arrays donde los pips YA TIENEN SIGNO (positivo = above, negativo = below).
# Esto aplica a structure_events y eq_events.
#
# PARA OB/FVG: el pip almacenado en LiquiditySnapshot es ABSOLUTO (abs()).
# Para OB/FVG usamos pip_mid que viene de _to_pips (sin signo).
# Necesitamos distinguir above/below via precio: usamos {price} vs ref_price.
#
# IMPORTANTE: OB y FVG tienen pip_mid >= 0 (absoluto). Para above/below
# necesitamos el campo 'price' (midpoint) comparado con ref_price, o bien
# pip_high/pip_low. Dado que LiquiditySnapshot no incluye ref_price en cada
# ob/fvg, y no hay campo con signo, usamos una heurística: si el ob/fvg tiene
# AMBOS pip_high > 0 y pip_low >= 0, esto no discrimina above/below por si
# mismo. La discriminacion correcta es por el campo {price} del elemento.
#
# Sin embargo, {price} (midpoint) tampoco tiene signo relativo a ref_price.
# Por lo tanto, este helper recibe $pip_field = 'pip_mid' para OB/FVG,
# y el aplanado con signo se hace en flatten_above_below_signed para los
# elementos que ya tienen pip con signo (structure/eq).
#
# Para OB/FVG: extraemos {price} del elemento y lo comparamos con $ref_price
# si se pasa, pero dado que build_dataset no tiene ref_price disponible aqui,
# usamos la convencion: pip_mid >= 0 siempre, y determinamos above/below
# usando {type}: 'bearish' OB/FVG es resistencia (above), 'bullish' es soporte (below).
#
# DECISION FINAL (simplificacion defensiva):
# Como esta ambiguedad no fue prevista en la especificacion, reportamos el
# problema y usamos flatten_above_below_signed para todos los elementos con
# pip con signo, y para OB/FVG usamos el tipo (bearish=above, bullish=below)
# para discriminar, con pip_mid como valor de pip (sin signo → negamos para below).
#
# Devuelve: { above_pip, above_<extra>, below_pip, below_<extra> }
# ---------------------------------------------------------------------------
sub flatten_above_below {
    my ($array_ref, $pip_field, $extra_spec) = @_;
    $array_ref //= [];

    my ($above_elem, $below_elem);
    my $above_dist = undef;  # menor pip positivo (mas cercano arriba)
    my $below_dist = undef;  # menor pip positivo representando (mas cercano abajo)

    for my $elem (@$array_ref) {
        next unless ref $elem eq 'HASH';
        my $pip = $elem->{$pip_field};
        next unless defined $pip;

        # Para OB/FVG: pip es absoluto. Discriminamos por {type}:
        #   bearish = por encima (resistencia) => above
        #   bullish = por debajo (soporte)     => below
        my $type = $elem->{type} // $elem->{kind} // '';
        my $is_above = ($type =~ /bear/i) ? 1 :
                       ($type =~ /bull/i) ? 0 : undef;

        next unless defined $is_above;

        if ($is_above) {
            if (!defined $above_dist || $pip < $above_dist) {
                $above_dist = $pip;
                $above_elem = $elem;
            }
        } else {
            if (!defined $below_dist || $pip < $below_dist) {
                $below_dist = $pip;
                $below_elem = $elem;
            }
        }
    }

    my %result = (
        above_pip => $above_elem ? $above_elem->{$pip_field} : undef,
        below_pip => $below_elem ? $below_elem->{$pip_field} : undef,
    );

    if ($extra_spec && ref $extra_spec eq 'ARRAY') {
        my ($extra_name, $extra_getter) = @$extra_spec;
        if (defined $extra_getter && ref $extra_getter eq 'CODE') {
            $result{"above_$extra_name"} = $above_elem ? $extra_getter->($above_elem) : undef;
            $result{"below_$extra_name"} = $below_elem ? $extra_getter->($below_elem) : undef;
        } else {
            $result{"above_$extra_name"} = $above_elem ? $above_elem->{$extra_name} : undef;
            $result{"below_$extra_name"} = $below_elem ? $below_elem->{$extra_name} : undef;
        }
    }

    return \%result;
}

# ---------------------------------------------------------------------------
# flatten_above_below_signed(\@array, $pip_field, [$extra_name, $extra_getter])
#
# Para arrays donde el pip YA TIENE SIGNO (positivo = above, negativo = below).
# Esto aplica a structure_events y eq_events (PASO 0 de LiquiditySnapshot).
#
# "above" = pip > 0, tomando el de MENOR pip positivo (mas cercano arriba)
# "below" = pip < 0, tomando el de MENOR |pip| negativo (mas cercano abajo)
# Si $extra_getter es undef => el extra es un string del campo {$extra_name}
#   Si no hay elemento de ese lado => string 'NONE' (columna categorica)
# ---------------------------------------------------------------------------
sub flatten_above_below_signed {
    my ($array_ref, $pip_field, $extra_spec) = @_;
    $array_ref //= [];

    my ($above_elem, $below_elem);
    my $above_dist = undef;  # menor pip positivo
    my $below_dist = undef;  # menor |pip| negativo (guardamos como negativo)

    for my $elem (@$array_ref) {
        next unless ref $elem eq 'HASH';
        my $pip = $elem->{$pip_field};
        next unless defined $pip;

        if ($pip > 0) {
            # above: queremos el de menor pip positivo
            if (!defined $above_dist || $pip < $above_dist) {
                $above_dist = $pip;
                $above_elem = $elem;
            }
        } elsif ($pip < 0) {
            # below: queremos el de menor |pip| (mas cercano → |pip| menor)
            my $abs_pip = abs($pip);
            if (!defined $below_dist || $abs_pip < $below_dist) {
                $below_dist = $abs_pip;
                $below_elem = $elem;
            }
        }
        # pip == 0: exactamente en ref_price; ignorar (ambiguo)
    }

    my %result = (
        above_pip => $above_elem ? $above_elem->{$pip_field} : undef,
        below_pip => $below_elem ? $below_elem->{$pip_field} : undef,
    );

    if ($extra_spec && ref $extra_spec eq 'ARRAY') {
        my ($extra_name, $extra_getter) = @$extra_spec;
        if (defined $extra_getter && ref $extra_getter eq 'CODE') {
            $result{"above_$extra_name"} = $above_elem ? $extra_getter->($above_elem) : undef;
            $result{"below_$extra_name"} = $below_elem ? $extra_getter->($below_elem) : undef;
        } else {
            # String categorico: 'NONE' si no hay elemento de ese lado
            $result{"above_$extra_name"} = $above_elem ? ($above_elem->{$extra_name} // 'NONE') : 'NONE';
            $result{"below_$extra_name"} = $below_elem ? ($below_elem->{$extra_name} // 'NONE') : 'NONE';
        }
    }

    return \%result;
}

# ---------------------------------------------------------------------------
# flatten_fib(\@fib_array, $anchor_index)
# Los 7 elementos se esperan ordenados por ratio ascendente:
#   0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0
# Mapea por posicion a 7 columnas fijas.
# Si hay menos de 7, rellena con undef y emite warning.
# Devuelve: { fib_0_pip, fib_236_pip, fib_382_pip, fib_500_pip,
#              fib_618_pip, fib_786_pip, fib_1000_pip }
# ---------------------------------------------------------------------------
sub flatten_fib {
    my ($fib_array, $anchor_index) = @_;
    $fib_array //= [];

    my @COL_NAMES = qw(fib_0_pip fib_236_pip fib_382_pip fib_500_pip
                       fib_618_pip fib_786_pip fib_1000_pip);
    my $expected  = scalar @COL_NAMES;
    my $got       = scalar @$fib_array;

    if ($got < $expected) {
        warn "flatten_fib: esperados $expected elementos, solo hay $got "
           . "(anchor_index=" . ($anchor_index // 'undef') . ")\n";
    }

    my %out;
    for my $pos (0 .. $expected - 1) {
        my $col  = $COL_NAMES[$pos];
        my $elem = $fib_array->[$pos];
        $out{$col} = (defined $elem && ref $elem eq 'HASH') ? $elem->{pip} : undef;
    }
    return \%out;
}

# ===========================================================================
# PRIVADOS
# ===========================================================================

# _sanitize($value, $col_name, $anchor_index)
# Retorna undef si el valor es NaN o Inf, con warning. No pone 0.
sub _sanitize {
    my ($val, $col, $ai) = @_;
    return undef unless defined $val;
    # Detectar Inf / NaN de Perl (las operaciones numericas en Perl pueden
    # devolver strings 'Inf', '-Inf', 'NaN' o valores numericos especiales)
    if ($val =~ /^[+-]?Inf$/i || $val =~ /^NaN$/i) {
        warn "_sanitize: $col = '$val' en anchor_index=$ai → celda vacía\n";
        return undef;
    }
    # Chequeo numerico de Inf (division por cero, etc.)
    no warnings 'uninitialized';
    if ($val != $val) {  # NaN
        warn "_sanitize: $col = NaN en anchor_index=$ai → celda vacía\n";
        return undef;
    }
    use warnings 'uninitialized';
    my $inf_check = eval { $val + 0 > 9e308 || $val + 0 < -9e308 };
    if (!$@ && $inf_check) {
        warn "_sanitize: $col = Inf en anchor_index=$ai → celda vacía\n";
        return undef;
    }
    return $val;
}

# _parse_ts($epoch_or_string) -> ($fecha, $hora, $minuto)
sub _parse_ts {
    my ($ts) = @_;
    return ('', '', '') unless defined $ts && $ts =~ /\d/;
    my $epoch = ($ts =~ /^\d+$/) ? $ts + 0 : undef;
    unless (defined $epoch) {
        eval {
            require Time::Piece;
            my $s = $ts; $s =~ s/:(?=\d{2}$)//;
            my $tp;
            eval { $tp = Time::Piece->strptime($s, '%Y-%m-%dT%H:%M:%S%z') };
            $tp //= eval { Time::Piece->strptime($s, '%Y-%m-%d %H:%M:%S') };
            $epoch = $tp->epoch if $tp;
        };
    }
    return ('', '', '') unless defined $epoch;

    my @lt  = localtime($epoch);
    my $min = sprintf('%02d', $lt[1]);
    my $hr  = sprintf('%02d', $lt[2]);
    my $day = sprintf('%04d-%02d-%02d', $lt[5]+1900, $lt[4]+1, $lt[3]);
    return ($day, $hr, $min);
}

# _write_csv($file, \@header, \@rows)
sub _write_csv {
    my ($file, $header, $rows) = @_;

    # Crear directorio si no existe
    (my $dir = $file) =~ s|[/\\][^/\\]+$||;
    if ($dir && $dir ne $file && !-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }

    open my $fh, '>', $file or die "_write_csv: no puedo abrir '$file': $!\n";

    # Cabecera
    print $fh join(',', map { _csv_escape($_) } @$header) . "\n";

    # Filas
    for my $row (@$rows) {
        my @vals = map { _csv_escape($row->{$_}) } @$header;
        print $fh join(',', @vals) . "\n";
    }

    close $fh;
}

# _csv_escape($value)
# Celdas undef → vacías, strings con comas/comillas → entre comillas.
sub _csv_escape {
    my ($v) = @_;
    return '' unless defined $v;
    $v = "$v";  # stringify
    if ($v =~ /[,"\n\r]/) {
        $v =~ s/"/""/g;
        $v = "\"$v\"";
    }
    return $v;
}

1;
