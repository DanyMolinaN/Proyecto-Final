package Market::Strategies::Indicators::SupplyDemand;

use strict;
use warnings;

# =============================================================================
# Market::Strategies::Indicators::SupplyDemand
# =============================================================================
# Engine de zonas de Supply y Demand con filtrado robusto:
#
#   1. Solo considera velas con cuerpo >= body_ratio del rango (default 50%)
#   2. Detección de mitigación: la zona se invalida si el precio la cruza por completo
#   3. Fusión de zonas solapadas del mismo tipo con overlap >= merge_threshold (75%)
#   4. Límite de zonas devueltas: max_zones (default 30, más recientes y más fuertes)
#   5. Priorización temporal: se ignoran zonas más antiguas que lookback_zones_bars
#      velas desde la vela actual evaluada
#
# =============================================================================

sub new {
    my ($class, %args) = @_;
    my $self = {
        lookback           => $args{lookback}           || 20,
        strength           => $args{strength}           || 3,
        body_ratio         => $args{body_ratio}         || 0.5,   # cuerpo mínimo como fracción del rango
        max_zones          => $args{max_zones}          || 30,    # cap de zonas devueltas
        merge_threshold    => $args{merge_threshold}    || 0.75,  # overlap mínimo para fusionar
        lookback_zones_bars => $args{lookback_zones_bars} || 500, # barra máxima de antigüedad
        zones              => [],
        signals            => [],
        metadata           => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{zones}    = [];
    $self->{signals}  = [];
    $self->{metadata} = {};
    return $self;
}

# ---------------------------------------------------------------------------
# calculate($market_data, %args) → { zones, signals, metadata }
# ---------------------------------------------------------------------------
sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $limit    = _visible_limit($market_data, $args{replay_controller});
    my $lookback = $self->{lookback};

    # Recopilar velas hasta el límite visible
    my @candles;
    for (my $i = 0; $i < $market_data->size(); $i++) {
        last if defined $limit && $i > $limit;
        my $c = $market_data->get_candle($i);
        push @candles, $c if $c;
    }
    return {} unless @candles;

    my $eval_idx = defined $limit && $limit >= 0 ? $limit : $#candles;

    # ── Fase 1: Detección de zonas candidatas ────────────────────────────────
    my @raw_zones;
    for my $i ($lookback - 1 .. $#candles) {
        # Ignorar zonas demasiado antiguas (no aportan contexto reciente)
        next if ($eval_idx - $i) > $self->{lookback_zones_bars};

        my $candle = $candles[$i];
        next unless $candle;

        my $body  = abs($candle->{close} - $candle->{open});
        my $range = $candle->{high} - $candle->{low};
        next if $range <= 0;
        next if $body < ($range * $self->{body_ratio});  # cuerpo insuficiente

        my $is_supply = $candle->{close} < $candle->{open};
        my $is_demand = $candle->{close} > $candle->{open};

        next unless $is_supply || $is_demand;

        # Score de fuerza: basado en el movimiento posterior a la zona
        # (cuanto más se movió el precio desde la zona, mayor el score)
        my $post_move = _post_zone_move(\@candles, $i, $eval_idx, $is_supply);

        my $zone = {
            type               => $is_supply ? 'supply' : 'demand',
            index              => $i,
            high               => $candle->{high},
            low                => $candle->{low},
            strength           => $self->{strength},
            confirmation_index => $i,
            score              => $body / $range + $post_move * 0.5,
            mitigated          => 0,
            invalidated_index  => undef,
        };
        push @raw_zones, $zone;
    }

    # ── Fase 2: Detección de mitigación ──────────────────────────────────────
    # Una zona se considera mitigada si el precio la atravesó completamente
    # en alguna vela posterior a su formación.
    _mark_mitigated(\@raw_zones, \@candles);

    # ── Fase 3: Filtrar zonas mitigadas ──────────────────────────────────────
    my @active_supply = grep { $_->{type} eq 'supply' && !$_->{mitigated} } @raw_zones;
    my @active_demand = grep { $_->{type} eq 'demand' && !$_->{mitigated} } @raw_zones;

    # ── Fase 4: Fusionar zonas solapadas del mismo tipo ──────────────────────
    @active_supply = _merge_zones(\@active_supply, $self->{merge_threshold});
    @active_demand = _merge_zones(\@active_demand, $self->{merge_threshold});

    # ── Fase 5: Ordenar por score descendente y aplicar cap ──────────────────
    my $half_cap = int($self->{max_zones} / 2);
    @active_supply = (sort { $b->{score} <=> $a->{score} } @active_supply)[0 .. $half_cap - 1];
    @active_demand = (sort { $b->{score} <=> $a->{score} } @active_demand)[0 .. $half_cap - 1];

    # Eliminar undefs del slice
    @active_supply = grep { defined $_ } @active_supply;
    @active_demand = grep { defined $_ } @active_demand;

    # ── Fase 6: Marcar confluencias (zonas supply y demand solapadas) ─────────
    _mark_confluences(\@active_supply, \@active_demand);

    my @all_zones = (@active_supply, @active_demand);

    # ── Fase 7: Señales (contacto con zona en la vela actual) ────────────────
    my @signals;
    if ($eval_idx >= 0 && $candles[$eval_idx]) {
        my $c = $candles[$eval_idx];
        for my $zone (@all_zones) {
            if ($c->{high} >= $zone->{low} && $c->{low} <= $zone->{high}) {
                push @signals, {
                    index => $eval_idx,
                    type  => $zone->{type} . '_touched',
                    zone  => $zone,
                };
                last;
            }
        }
    }

    $self->{zones}   = \@all_zones;
    $self->{signals} = \@signals;
    $self->{metadata} = {
        timeframe          => $args{timeframe} || $market_data->active_tf(),
        visible_limit      => $limit,
        lookback           => $lookback,
        raw_count          => scalar(@raw_zones),
        mitigated_count    => scalar(grep { $_->{mitigated} } @raw_zones),
        zone_count         => scalar(@all_zones),
        supply_count       => scalar(@active_supply),
        demand_count       => scalar(@active_demand),
    };

    return {
        zones    => $self->{zones},
        signals  => $self->{signals},
        metadata => $self->{metadata},
    };
}

sub signals {
    my ($self) = @_;
    return $self->{signals} || [];
}

# ---------------------------------------------------------------------------
# _post_zone_move(\@candles, $zone_idx, $eval_idx, $is_supply)
# Calcula el movimiento máximo del precio desde la zona hasta el final visible.
# Normalizado al rango de la zona para ser comparable entre zonas.
# ---------------------------------------------------------------------------
sub _post_zone_move {
    my ($candles, $zone_idx, $eval_idx, $is_supply) = @_;
    my $zone_candle = $candles->[$zone_idx];
    return 0 unless $zone_candle;

    my $zone_range = $zone_candle->{high} - $zone_candle->{low};
    return 0 if $zone_range <= 0;

    my $max_move = 0;
    my $ref_price = $is_supply ? $zone_candle->{low} : $zone_candle->{high};

    # Limitar la ventana a 100 velas post-zona para eficiencia
    my $window_end = $zone_idx + 100;
    $window_end = $eval_idx if $window_end > $eval_idx;

    for my $j ($zone_idx + 1 .. $window_end) {
        my $c = $candles->[$j];
        next unless $c;
        my $move = $is_supply
            ? ($ref_price - $c->{low})   # supply: precio bajó desde la zona
            : ($c->{high} - $ref_price); # demand: precio subió desde la zona
        $max_move = $move if $move > $max_move;
    }

    return $max_move / $zone_range;  # normalizado
}

# ---------------------------------------------------------------------------
# _mark_mitigated(\@zones, \@candles)
# Marca las zonas donde el precio atravesó completamente la zona:
#   - supply mitigada: una vela posterior cerró por encima del high de la zona
#   - demand mitigada: una vela posterior cerró por debajo del low de la zona
# ---------------------------------------------------------------------------
sub _mark_mitigated {
    my ($zones, $candles) = @_;
    for my $zone (@$zones) {
        my $start = $zone->{index} + 1;
        my $end   = $#$candles;
        for my $j ($start .. $end) {
            my $c = $candles->[$j];
            next unless $c;
            if ($zone->{type} eq 'supply' && $c->{close} > $zone->{high}) {
                $zone->{mitigated}         = 1;
                $zone->{invalidated_index} = $j;
                last;
            }
            elsif ($zone->{type} eq 'demand' && $c->{close} < $zone->{low}) {
                $zone->{mitigated}         = 1;
                $zone->{invalidated_index} = $j;
                last;
            }
        }
    }
}

# ---------------------------------------------------------------------------
# _merge_zones(\@zones, $threshold) → @merged
# Fusiona zonas solapadas del mismo tipo cuando el overlap supera el threshold.
# El overlap se calcula como: (intersección / min(zona1, zona2)).
# La zona fusionada hereda el índice más reciente, el score más alto y
# los extremos más amplios (high máximo, low mínimo).
# ---------------------------------------------------------------------------
sub _merge_zones {
    my ($zones, $threshold) = @_;
    return () unless @$zones;

    # Ordenar de más antiguo a más reciente para que el merge sea determinista
    my @sorted = sort { $a->{index} <=> $b->{index} } @$zones;
    my @merged;

    ZONE: for my $zone (@sorted) {
        for my $m (@merged) {
            my $inter_high = $m->{high} < $zone->{high} ? $m->{high} : $zone->{high};
            my $inter_low  = $m->{low}  > $zone->{low}  ? $m->{low}  : $zone->{low};
            next unless $inter_high > $inter_low;  # sin solapamiento

            my $inter_size = $inter_high - $inter_low;
            my $size1 = $m->{high}    - $m->{low};
            my $size2 = $zone->{high} - $zone->{low};
            my $min_size = $size1 < $size2 ? $size1 : $size2;
            next if $min_size <= 0;

            my $overlap_ratio = $inter_size / $min_size;
            if ($overlap_ratio >= $threshold) {
                # Fusionar: ampliar los extremos, actualizar score e índice
                $m->{high}  = $m->{high}  > $zone->{high}  ? $m->{high}  : $zone->{high};
                $m->{low}   = $m->{low}   < $zone->{low}   ? $m->{low}   : $zone->{low};
                $m->{score} = $m->{score} > $zone->{score} ? $m->{score} : $zone->{score};
                $m->{index} = $zone->{index};   # índice más reciente
                $m->{confirmation_index} = $zone->{confirmation_index};
                next ZONE;
            }
        }
        push @merged, { %$zone };   # copia la zona sin fusionar
    }

    return @merged;
}

# ---------------------------------------------------------------------------
# _mark_confluences(\@supply, \@demand)
# Marca zonas supply y demand que se solapan como "confluence".
# Una confluencia indica tensión de precio en esa área.
# ---------------------------------------------------------------------------
sub _mark_confluences {
    my ($supply_zones, $demand_zones) = @_;
    for my $s (@$supply_zones) {
        for my $d (@$demand_zones) {
            my $inter_high = $s->{high} < $d->{high} ? $s->{high} : $d->{high};
            my $inter_low  = $s->{low}  > $d->{low}  ? $s->{low}  : $d->{low};
            if ($inter_high > $inter_low) {
                $s->{confluence} = 1;
                $d->{confluence} = 1;
            }
        }
    }
}

# ---------------------------------------------------------------------------
# _visible_limit($market_data, $replay_controller)
# ---------------------------------------------------------------------------
sub _visible_limit {
    my ($market_data, $replay_controller) = @_;
    return undef unless $replay_controller && $replay_controller->can('visible_limit');
    return $replay_controller->visible_limit($market_data->size());
}

# ---------------------------------------------------------------------------
# _window_high_low(\@window) — mantenido por compatibilidad
# ---------------------------------------------------------------------------
sub _window_high_low {
    my ($window) = @_;
    my ($high, $low);
    for my $c (@$window) {
        next unless $c;
        $high = $c->{high} if !defined $high || $c->{high} > $high;
        $low  = $c->{low}  if !defined $low  || $c->{low}  < $low;
    }
    return ($high // 0, $low // 0);
}

1;
