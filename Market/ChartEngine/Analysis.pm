package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Analysis
# =============================================================================
# Cache de analisis y puentes SMC -> vista legacy de estructura.
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

sub invalidate_analysis_cache {
    my ($self) = @_;
    $self->{analysis_cache} = undef;
    if ($self->{engine_registry} && $self->{engine_registry}->can('invalidate')) {
        $self->{engine_registry}->invalidate();
    }
    return $self;
}

# rebuild_analysis_cache()
# Delega el calculo completo al EngineRegistry en orden de dependencias.
# ChartEngine NO orquesta engines directamente: eso es responsabilidad del
# registry (separacion estricta calculo / render).
sub rebuild_analysis_cache {
    my ($self) = @_;
    return unless $self->{market_data};
    return unless $self->{engine_registry};

    $self->compute_window() if !defined $self->{start_idx} || !defined $self->{end_idx};

    my $timeframe = $self->{active_tf} || $self->{market_data}->active_tf();
    my $visible   = $self->{current_visible_bars} || $self->{initial_visible_bars} || 250;
    my $buffer    = int($visible * 0.75);
    my $view_end  = $self->{end_idx};
    if (!defined $view_end) {
        my $total = $self->{market_data}->size();
        $view_end = $total - 1 if $total > 0;
    }
    my $view_start = defined $self->{start_idx} ? $self->{start_idx} - $buffer : 0;
    $view_start = 0 if $view_start < 0;

    # Argumentos comunes a todos los engines (cada engine solo usa los que
    # necesita; los extra se ignoran silenciosamente).
    my %engine_args = (
        replay_controller => $self->{replay_controller},
        timeframe         => $timeframe,
        view_start        => $view_start,
        view_end          => $view_end,
        overlay_settings  => $self->{overlay_settings},
    );

    # Activar modo visible_only en Liquidity si lo soporta
    my $liq_eng = $self->{engine_registry}->get('liquidity');
    if ($liq_eng && $liq_eng->can('visible_only')) {
        $liq_eng->visible_only(1);
    }

    # El EngineRegistry calcula todos los engines en orden de registro,
    # resolviendo dependencias automaticamente via los calcs declarados.
    my $raw_cache = $self->{engine_registry}->rebuild(
        $self->{market_data}, %engine_args
    );

    # Post-proceso del cache SMC: enriquecer liquidity con estructura
    my $smc_structure_data = $raw_cache->{smc_structure} || {};
    my $liquidity_data     = $raw_cache->{liquidity}     || {};

    if (ref $liquidity_data eq 'HASH') {
        $liquidity_data->{eq_levels} = $self->_eq_levels_from_smc_structure($smc_structure_data);
        if ($liq_eng && $liq_eng->can('apply_structure_filter')) {
            my $filtered = $liq_eng->apply_structure_filter(
                $smc_structure_data, $self->{market_data}, %engine_args,
            );
            $liquidity_data = $filtered if $filtered;
            $liquidity_data->{eq_levels} //= $self->_eq_levels_from_smc_structure($smc_structure_data);
        }
        $self->_enrich_liquidity_with_structure_scope($liquidity_data, $smc_structure_data);
    }

    # Construir vista legacy de estructura (para overlays que la esperan)
    my $structure_data = $self->_legacy_structure_view_from_smc($smc_structure_data);

    $self->{analysis_cache} = {
        liquidity         => $liquidity_data,
        structure         => $structure_data,
        smc_structure     => $smc_structure_data,
        fvg               => $raw_cache->{fvg},
        orderblock        => $raw_cache->{orderblock},
        volume_profile    => $raw_cache->{volume_profile},
        anchored_vwap     => $raw_cache->{anchored_vwap},
        fibonacci         => $raw_cache->{fibonacci},
        supply_demand     => $raw_cache->{supply_demand},
        trend_channel     => $raw_cache->{trend_channel},
        trailing_extremes => $raw_cache->{trailing_extremes},
        premium_discount  => $raw_cache->{premium_discount},
        mtf_levels        => $raw_cache->{mtf_levels},
        zzmtf_overlay     => $raw_cache->{zzmtf_overlay},
    };
    return $self->{analysis_cache};
}

# _enrich_liquidity_with_structure_scope($liquidity_data, $structure_data)
# Propaga scope external/internal a niveles de liquidez para evitar duplicar
# etiquetas BSL/SSL en swings internos (SMC ya etiqueta la estructura).
sub _enrich_liquidity_with_structure_scope {
    my ($self, $liquidity_data, $structure_data) = @_;
    return unless $liquidity_data && ref $liquidity_data eq 'HASH';
    return unless $structure_data && ref $structure_data eq 'HASH';

    my %scope_by_index;
    for my $sw (@{ $structure_data->{external_swings} || $structure_data->{swings} || [] }) {
        next unless $sw && ref $sw eq 'HASH';
        next unless defined $sw->{index};
        $scope_by_index{ $sw->{index} } = $sw->{scope} // 'internal';
    }

    my $levels = $liquidity_data->{liquidity_levels};
    return unless $levels && ref $levels eq 'ARRAY';

    for my $lvl (@$levels) {
        next unless $lvl && ref $lvl eq 'HASH';
        my $idx = $lvl->{created_index} // $lvl->{index};
        $lvl->{scope} = defined $idx ? ($scope_by_index{$idx} // 'internal') : 'internal';
    }

    $liquidity_data->{metadata}{structure_coordinated} = 1;
    return $liquidity_data;
}

sub _eq_levels_from_smc_structure {
    my ($self, $smc_structure_data) = @_;
    return [] unless $smc_structure_data && ref $smc_structure_data eq 'HASH';

    my @levels;
    for my $pair (
        [ eqh => 'EQH' ],
        [ eql => 'EQL' ],
    ) {
        my ($key, $type) = @$pair;
        for my $evt (@{ $smc_structure_data->{$key} || [] }) {
            next unless $evt && ref $evt eq 'HASH';
            next unless defined $evt->{level};
            # Origen/fin del Equal High/Low = los dos pivotes iguales
            # (prev_index → swing_index). Fallback a indices legacy si faltan.
            my $first  = $evt->{prev_index}  // $evt->{swing_index};
            my $second = $evt->{swing_index} // $evt->{index};
            next unless defined $first && defined $second;
            push @levels, {
                first_index  => $first,
                second_index => $second,
                level        => $evt->{level},
                type         => $type,
                start_index  => $evt->{start_index} // $first,
                end_index    => $evt->{end_index},
                is_open      => $evt->{is_open} ? 1 : 0,
                source       => 'SMCStructureEngine',
            };
        }
    }
    return [ sort { ($a->{second_index} // 0) <=> ($b->{second_index} // 0) } @levels ];
}

sub _legacy_structure_view_from_smc {
    my ($self, $smc_structure_data) = @_;
    return {} unless $smc_structure_data && ref $smc_structure_data eq 'HASH';

    my @external = (
        ( map { { %$_, price => $_->{level}, kind => 'high', scope => 'external', type => 'swing' } }
            @{ $smc_structure_data->{swing_highs} || [] } ),
        ( map { { %$_, price => $_->{level}, kind => 'low',  scope => 'external', type => 'swing' } }
            @{ $smc_structure_data->{swing_lows}  || [] } ),
    );
    my @internal = (
        ( map { { %$_, price => $_->{level}, kind => 'high', scope => 'internal', type => 'swing' } }
            @{ $smc_structure_data->{internal_highs} || [] } ),
        ( map { { %$_, price => $_->{level}, kind => 'low',  scope => 'internal', type => 'swing' } }
            @{ $smc_structure_data->{internal_lows}  || [] } ),
    );

    my @breaks;
    my @changes;
    for my $evt (@{ $smc_structure_data->{events} || [] }) {
        next unless $evt && ref $evt eq 'HASH';
        next unless ($evt->{kind} || '') =~ /^(?:BOS|CHoCH)$/;
        my $mapped = {
            %$evt,
            type               => $evt->{kind},
            confirmation_index => $evt->{index},
            break_index        => $evt->{swing_index},
        };
        if ($evt->{kind} eq 'BOS') {
            push @breaks, $mapped;
        }
        else {
            push @changes, $mapped;
        }
    }

    return {
        swings          => [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @external ],
        external_swings => [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @external ],
        internal_swings => [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @internal ],
        trend           => $smc_structure_data->{swing_trend} || 'neutral',
        breaks          => \@breaks,
        changes         => \@changes,
        metadata        => {
            %{ $smc_structure_data->{metadata} || {} },
            source => 'SMCStructureEngine',
        },
    };
}

sub _prepare_overlay_data {
    my ($self) = @_;
    return unless $self->{overlay_manager};
    return unless $self->{market_data};

    # DESACOPLE ANALISIS/RENDER: aqui NO se recalcula Liquidity/Structure/FVG/
    # Order Blocks/VWAP. Se consumen desde analysis_cache (construida solo al
    # cambiar los datos). Si la cache no existe (primer render o tras invalidar),
    # se reconstruye una unica vez de forma perezosa.
    $self->rebuild_analysis_cache() unless $self->{analysis_cache};
    my $cache = $self->{analysis_cache} || {};

    my $liquidity_data = $cache->{liquidity};
    my $structure_data = $cache->{structure};
    my $fvg_data       = $cache->{fvg};
    my $orderblock_data = $cache->{orderblock};
    my $volume_profile_data = $cache->{volume_profile};
    my $anchored_vwap_data = $cache->{anchored_vwap};
    my $fibonacci_data = $cache->{fibonacci};
    my $supply_demand_data = $cache->{supply_demand};
    my $trend_channel_data = $cache->{trend_channel};
    
    # Phase 2
    my $trailing_extremes_data = $cache->{trailing_extremes};
    my $premium_discount_data  = $cache->{premium_discount};
    my $mtf_levels_data        = $cache->{mtf_levels};
    my $zzmtf_overlay_data     = $cache->{zzmtf_overlay};

    my $overlay_names = {
        liquidity      => $liquidity_data,
        structure      => $structure_data || $cache->{smc_structure},
        fvg            => $fvg_data,
        orderblock     => $orderblock_data,
        volume_profile => $volume_profile_data,
        anchored_vwap  => $anchored_vwap_data,
        fibonacci      => $fibonacci_data,
        supply_demand  => $supply_demand_data,
        trend_channel  => $trend_channel_data,
        trailing_extremes => $trailing_extremes_data,
        premium_discount  => $premium_discount_data,
        mtf_levels        => $mtf_levels_data,
        zzmtf_overlay     => $zzmtf_overlay_data,
    };

    for my $name (keys %$overlay_names) {
        next unless $self->{overlay_manager}->can('get');
        my $overlay = $self->{overlay_manager}->get($name);
        next unless $overlay && $overlay->can('set_data');
        $overlay->set_data($overlay_names->{$name});
    }

    return $self;
}

# _in_price_panel($y) -> bool
# Verdadero si Y cae dentro del panel de precios (no ATR ni eje de tiempo).

1;