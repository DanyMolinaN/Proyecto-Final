package Market::Concepts::DSVWAP::GhostTrailCounter;

use strict;
use warnings;
use Market::Concepts::DSVWAP::LiquiditySnapshot;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::GhostTrailCounter
# Responsabilidad: Cuenta los rastros historicos dejados por los fantasmas
# (GhostTrailEvent) relativos a cada aparicion (AnchorChangedEvent).
# Funciona en modo incremental (para el Chart) y modo batch (para la tabla ML).
#
# Fase 1 agrega count_trails_batch_with_snapshot(), que enriquece cada
# aparicion con el snapshot de multi-temporalidad (10m y 1H) libre de leakage.
# =============================================================================

sub new {
    my ($class, $event_bus, $cache) = @_;
    my $self = {
        bus    => $event_bus,
        cache  => $cache,

        # Almacenara los rastros acumulados de la iteracion en vivo
        current_trails => [],

        # Almacenara el registro historico para modo batch
        history_appearances => [],
        history_trails      => [],
    };
    bless $self, $class;

    $self->{bus}->subscribe('AnchorChangedEvent', sub { $self->_on_anchor_changed(@_) });
    $self->{bus}->subscribe('GhostTrailEvent',    sub { $self->_on_ghost_trail(@_) });

    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{current_trails} = [];
    $self->{history_appearances} = [];
    $self->{history_trails} = [];
    $self->{cache}->{ghost_trails} = $self->{current_trails};
}

sub _on_anchor_changed {
    my ($self, $event) = @_;

    # Cada vez que cambia el ancla, limpiamos los rastros "vivos" del overlay
    $self->{current_trails} = [];
    $self->{cache}->{ghost_trails} = $self->{current_trails};

    # Registramos la aparicion para el modo batch.
    # Guardamos ts si viene en el evento (para LiquiditySnapshot en Fase 1).
    push @{$self->{history_appearances}}, {
        index => $event->{index},
        price => $event->{price},
        dir   => $event->{direction}, # 1 Low, -1 High
        ts    => $event->{ts},        # timestamp epoch de la vela de aparicion (puede ser undef)
    };
}

sub _on_ghost_trail {
    my ($self, $event) = @_;

    # Guardamos en la memoria viva para el Overlay (se borra con cada ancla)
    push @{$self->{current_trails}}, $event;
    $self->{cache}->{ghost_trails} = $self->{current_trails};

    # Guardamos en el historial completo para el modo batch
    push @{$self->{history_trails}}, $event;
}

# -----------------------------------------------------------------------------
# Modo batch (para entrenamiento ML)
#
# Para cada aparicion en indice A, cuenta todos los GhostTrailEvents cuyo
# bar-index caiga estrictamente en (A, A+N] para N en {3, 5, 10, 15}.
#
# MODELO CORRECTO: el rail '1' del Pine ocurre cuando la vela ACTUAL (barra
# confirmada) es el nuevo extremo del fantasma. No importa a que ancla
# "pertenece" el trail - lo que interesa es cuantos rastros aparecen en la
# ventana de N velas 1m POSTERIOR a la aparicion del fantasma.
# Ejemplo: aparicion en bar 500 => trails_3m = # trails con index en {501,502,503}
#
# Implementacion O(T log T + A*log T): construimos un array ordenado de indices
# de trail y usamos busqueda binaria para contar en cada ventana.
# -----------------------------------------------------------------------------
sub count_trails_batch {
    my ($self) = @_;

    # Construir array ordenado de bar-indices de trails.
    my @trail_indices = sort { $a <=> $b }
                        map  { $_->{index} }
                        @{ $self->{history_trails} };

    my @results;

    for my $app (@{ $self->{history_appearances} }) {
        my $a = $app->{index};

        # Contamos trails en (a, a+N] con busqueda binaria.
        my $c_3  = _count_in_range($a, $a + 3,  \@trail_indices);
        my $c_5  = _count_in_range($a, $a + 5,  \@trail_indices);
        my $c_10 = _count_in_range($a, $a + 10, \@trail_indices);
        my $c_15 = _count_in_range($a, $a + 15, \@trail_indices);

        # Verificacion de monotonia (invariante garantizado por construccion).
        if (!($c_3 <= $c_5 && $c_5 <= $c_10 && $c_10 <= $c_15)) {
            warn "BUG DETECTADO: Monotonia rota para ancla en index $a. " .
                 "Conteos: 3m=$c_3, 5m=$c_5, 10m=$c_10, 15m=$c_15\n";
        }

        push @results, {
            anchor_index => $a,
            anchor_price => $app->{price},
            anchor_dir   => $app->{dir},
            trails_3m    => $c_3,
            trails_5m    => $c_5,
            trails_10m   => $c_10,
            trails_15m   => $c_15,
        };
    }

    return \@results;
}

# -----------------------------------------------------------------------------
# count_trails_batch_with_snapshot($market_data) -> \@results
#
# Extiende count_trails_batch agregando a cada registro el snapshot de
# multi-temporalidad (1m, 10m y 1H) de la vela cerrada inmediatamente anterior
# al momento de aparicion del fantasma. Cada TF incluye los 9 engines:
#   ob, fvg, fib, vwap (+ bandas), vp (POC/VAH/VAL), mtf (D/W), liq_events
# y la distancia en PIPs de cada nivel respecto al precio HLC3 de aparicion.
#
# ANTI-LEAKAGE garantizado por LiquiditySnapshot + find_closed_tf_index:
#   - Solo se usan buckets cuyo cierre fue completamente procesado antes
#     del timestamp de la vela de 1m de aparicion.
#   - Si no hay bucket cerrado disponible => undef (no se inventa nada).
#   - Caso edge: aparicion en el primer bucket de la TF => undef.
#
# Devuelve \@results con cada elemento conteniendo:
#   {
#     anchor_index, anchor_price, anchor_dir, anchor_ts, ref_price (HLC3),
#     trails_3m, trails_5m, trails_10m, trails_15m,
#     tf_1m  => { OHLCV + ob, fvg, fib, vwap, vp, mtf, liq_events } | undef,
#     tf_10m => idem con anti-leakage | undef,
#     tf_1h  => idem con anti-leakage | undef,
#   }
# -----------------------------------------------------------------------------
sub count_trails_batch_with_snapshot {
    my ($self, $market_data, %opts) = @_;

    # Primero obtenemos los conteos de trails (Fase 0, ya validados).
    my $base_results = $self->count_trails_batch();

    # Instanciar el modulo de snapshot.
    # pip_factor por defecto = 4 (COMEX Gold Futures GC/MGC):
    #   1 tick = $0.25  =>  pip_factor = 4  =>  1 pip = 1 tick
    #   Para Forex 5-digit usar pip_factor=10000; para NQ/ES usar segun tick.
    my $snapshot_engine = Market::Concepts::DSVWAP::LiquiditySnapshot->new(
        pip_factor => $opts{pip_factor}  // 4,
        window_1m  => $opts{window_1m}   // 500,
        window_10m => $opts{window_10m}  // 300,
    );

    # Construimos un indice rapido: anchor_index -> ts desde history_appearances.
    my %ts_by_index;
    for my $app (@{ $self->{history_appearances} }) {
        $ts_by_index{ $app->{index} } = $app->{ts};
    }

    # Para cada resultado base, enriquecemos con el snapshot completo (3 TFs + engines).
    my @enriched;
    for my $row (@$base_results) {
        my $ai = $row->{anchor_index};
        my $ts = $ts_by_index{$ai};

        # Si no hay timestamp en el evento (caso edge: ancla sin ts),
        # lo obtenemos desde market_data directamente.
        unless (defined $ts) {
            my $c1m = eval { $market_data->get_candle_in_tf('1m', $ai) };
            $ts = $c1m->{timestamp} if $c1m;
        }

        # snapshot_for_anchor devuelve: { anchor_ts, anchor_index, ref_price,
        #   tf_1m => {..., ob, fvg, fib, vwap, vp, mtf, liq_events},
        #   tf_10m => idem, tf_1h => idem }
        my $snap = defined $ts
            ? $snapshot_engine->snapshot_for_anchor($market_data, $ts, $ai)
            : { ref_price => undef, tf_1m => undef, tf_10m => undef, tf_1h => undef };

        push @enriched, {
            %$row,                        # trails_Xm, anchor_price, anchor_dir, anchor_index
            anchor_ts  => $ts,
            ref_price  => $snap->{ref_price},  # HLC3 de la vela de aparicion
            tf_1m      => $snap->{tf_1m},      # snapshot 1m con engines
            tf_10m     => $snap->{tf_10m},     # snapshot 10m con engines (anti-leakage)
            tf_1h      => $snap->{tf_1h},      # snapshot 1H con engines (anti-leakage)
        };
    }

    return \@enriched;
}

# _count_in_range($lo_excl, $hi_incl, \@sorted_ints)
# Retorna el numero de elementos en el array ordenado que caen en (lo, hi].
# Usa busqueda binaria para O(log n).
sub _count_in_range {
    my ($lo, $hi, $arr) = @_;
    return 0 unless @$arr;

    # lower_bound: primer indice con arr[i] > lo
    my ($l, $r) = (0, scalar @$arr);
    while ($l < $r) {
        my $m = int(($l + $r) / 2);
        $arr->[$m] <= $lo ? ($l = $m + 1) : ($r = $m);
    }
    my $left = $l;

    # upper_bound: primer indice con arr[i] > hi
    ($l, $r) = (0, scalar @$arr);
    while ($l < $r) {
        my $m = int(($l + $r) / 2);
        $arr->[$m] <= $hi ? ($l = $m + 1) : ($r = $m);
    }
    my $right = $l;

    return $right - $left;
}

1;
