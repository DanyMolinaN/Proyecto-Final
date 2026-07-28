package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine
# =============================================================================
# ARQUITECTURA: ChartEngine es exclusivamente un motor de RENDER.
# NO crea ni gestiona engines de analisis internamente.
# Los engines se inyectan via EngineRegistry desde market.pl.
#
# Organisation (SRP): el paquete se reparte en Market/ChartEngine/*.pm
# (mismo package Market::ChartEngine). La API publica no cambia.
#   Events | Controls | Replay | Geometry
#   Render | Analysis | Crosshair | Zoom | Interaction
# =============================================================================

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use Tk;
use Time::HiRes qw(time);
use lib File::Spec->catdir(dirname(__FILE__), '..');

# Activa el logging de diagnostico del wheel/zoom si la variable de entorno
# CHART_DEBUG_WHEEL=1 esta definida al arrancar market.pl. No afecta nada si
# no esta activada.
our $DEBUG_WHEEL = $ENV{CHART_DEBUG_WHEEL} ? 1 : 0;

use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;
use Market::Panels::Scales;
use Market::MarketData;
use Market::Core::OverlayManager;
use Market::Core::OverlaySettings;
use Market::Core::EngineRegistry;       # <-- registro ordenado de engines
use Market::Core::ReplayController;
use Market::Core::TimeframeManager;
use Market::Core::ViewportController;
use Market::Core::YAxisHitTest;
use Market::Core::VerticalScaleZoom;
use Market::Core::ATRPanelZoom;
use Market::Overlays::LiquidityOverlay;
use Market::Overlays::StructureOverlay;
use Market::Overlays::FVGOverlay;
use Market::Overlays::OrderBlockOverlay;
use Market::Overlays::VolumeProfileOverlay;
use Market::Overlays::TimePersistenceOverlay;
use Market::Overlays::DSVWAPOverlay;
use Market::Overlays::GhostTrailOverlay;
use Market::Overlays::AnchoredVWAPOverlay;
use Market::Overlays::FibonacciOverlay;
use Market::Overlays::SupplyDemandOverlay;
use Market::Overlays::TrendChannelOverlay;

# Phase 2 Overlays
use Market::Overlays::TrailingExtremesOverlay;
use Market::Overlays::PremiumDiscountOverlay;
use Market::Overlays::MTFLevelsOverlay;
use Market::Overlays::ZZMTFOverlay;

# Fase 6 — Demo: prediccion Ridge en vivo
use Market::Concepts::DSVWAP::GhostTrailPredictor;
use Market::Panels::GhostTrailPredictionPanel;

# --- Tools Extra ---
use Market::Indicators::ZigZagVP2David;
use Market::Indicators::ZigZagMTF2David;
use Market::Indicators::FibonacciDavid;
use Market::Indicators::LiquidityDavid;
use Market::Overlays::ZigZagVP2DavidOverlay;
use Market::Overlays::ZigZagMTF2DavidOverlay;
use Market::Overlays::FibonacciDavidOverlay;
use Market::Overlays::LiquidityDavidOverlay;
use Market::ChartEngine::ToolsExtra;

use Market::Indicators::AnchoredVWAPDavid;
use Market::Overlays::AnchoredVWAPDavidOverlay;

use Market::Indicators::PivotAnchorsDavid;
use Market::Overlays::PivotAnchorsDavidOverlay;
use Market::Indicators::AnchoredVolumeProfileDavid;
use Market::Overlays::AnchoredVolumeProfileDavidOverlay;

use Market::Indicators::SMCStructures2;
use Market::Overlays::SMCStructures2Overlay;


sub new {
    my ($class, %args) = @_;
    my $canvas            = $args{canvas};
    my $market_data       = $args{market_data};
    my $indicator_manager = $args{indicator_manager};
    return unless $canvas && $market_data;

    my $width        = $args{width}      || 1000;
    my $height       = $args{height}     || 700;
    # Panel ATR: ~14% del alto del canvas (estilo TradingView, no domina el precio).
    my $atr_height   = $args{atr_height} || 110;
    # Franja inferior reservada para el eje de tiempo comun (al fondo de TODO
    # el grafico, debajo del panel ATR), al estilo de TradingView. Su alto define
    # el margen inferior: con 42 px las etiquetas (baseline+12) y la caja del
    # crosshair (baseline+16) quedan ~15-20 px por encima del borde del canvas,
    # "respirando" en lugar de pegadas/recortadas abajo.
    my $time_axis_height = $args{time_axis_height} || 42;
    my $price_height = $height - $atr_height - $time_axis_height;

    # Tope de zoom-out MUY alto: el limite efectivo es el total de velas (se
    # acota en compute_window con `$visible = $total`). Asi se puede comprimir
    # TODA la data como en TradingView, sin un tope artificial intermedio.
    my $max_visible_bars = $args{max_visible_bars} || 1_000_000;
    my $initial_visible  = $args{visible_bars}     || 250;
    $initial_visible = $max_visible_bars if $initial_visible > $max_visible_bars;

    my $candle_width = $args{candle_width} || ($width / $initial_visible);

    my $price_scale = Market::Panels::Scales->new(
        width           => $width,
        height          => $price_height,
        candle_width    => $candle_width,
        start_index     => 0,
        axis_tag        => 'price_y_scale',
        axis_background => '#181c27',
        y_axis_strip_w  => 66,
    );
    my $atr_scale = Market::Panels::Scales->new(
        width           => $width,
        height          => $atr_height,
        candle_width    => $candle_width,
        start_index     => 0,
        y_offset        => $price_height,
        axis_tag        => 'atr_y_scale',
        axis_background => '#141b28',
        y_axis_strip_w  => 66,
    );

    # =========================================================================
    # EngineRegistry: fuente unica de engines analiticos.
    # Si se inyecta desde market.pl (patron nuevo), se usa directamente.
    # Si NO se inyecta (retrocompatibilidad), se construye uno interno con
    # los engines pasados individualmente como argumentos.
    # =========================================================================
    my $engine_registry = $args{engine_registry};
    unless ($engine_registry && $engine_registry->isa('Market::Core::EngineRegistry')) {
        # --- Retrocompatibilidad: construir EngineRegistry desde engines legacy ---
        $engine_registry = _build_legacy_engine_registry($indicator_manager, %args);
    }

    my $overlay_settings = $args{overlay_settings} || Market::Core::OverlaySettings->new();

    my $liquidity_overlay = Market::Overlays::LiquidityOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $structure_overlay = Market::Overlays::StructureOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $fvg_overlay = Market::Overlays::FVGOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $orderblock_overlay = Market::Overlays::OrderBlockOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $volume_profile_overlay = Market::Overlays::VolumeProfileOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $time_persistence_overlay = Market::Overlays::TimePersistenceOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $anchored_vwap_overlay = Market::Overlays::AnchoredVWAPOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $dsvwap_overlay = Market::Overlays::DSVWAPOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $ghost_trails_overlay = Market::Overlays::GhostTrailOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $fibonacci_overlay = Market::Overlays::FibonacciOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $supply_demand_overlay = Market::Overlays::SupplyDemandOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $trend_channel_overlay = Market::Overlays::TrendChannelOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );

    # Phase 2 Overlays
    my $trailing_extremes_overlay = Market::Overlays::TrailingExtremesOverlay->new(
        canvas => $canvas, scale => $price_scale, settings => $overlay_settings,
    );
    my $premium_discount_overlay = Market::Overlays::PremiumDiscountOverlay->new(
        canvas   => $canvas,
        scale    => $price_scale,
        settings => $overlay_settings,
    );
    my $mtf_levels_overlay = Market::Overlays::MTFLevelsOverlay->new(
        canvas   => $canvas,
        scale    => $price_scale,
        settings => $overlay_settings,
    );
    my $zzmtf_overlay = Market::Overlays::ZZMTFOverlay->new(
        canvas   => $canvas,
        scale    => $price_scale,
        settings => $overlay_settings,
    );

    # --- Tools Extra: indicadores y overlays (Fase 4) ---
    # Orden critico por cross-dependencies (plan seccion 4.4b):
    # 1. ZigZagVP2David (sin dependencias)
    # 2. ZigZagMTF2David (sin dependencias)
    # 3. FibonacciDavid (depende de ZigZagVP2David para modo auto)
    # 4. LiquidityDavid (depende de ATR existente + ambos ZigZag David)
    my $zzvp2d_ind = Market::Indicators::ZigZagVP2David->new(
        market_data => $market_data,
    );
    my $zzmtf2d_ind = Market::Indicators::ZigZagMTF2David->new(
        market_data => $market_data,
        resolution  => '5m',   # default; cambiable via ToolsExtra
    );
    my $fibd_ind = Market::Indicators::FibonacciDavid->new(
        market_data  => $market_data,
        source_zzvp2 => $zzvp2d_ind,   # modo auto usa pivots del ZigZagVP2
        mode         => 'auto',
    );
    my $avwapd_ind = Market::Indicators::AnchoredVWAPDavid->new(
        market_data => $market_data,
        mode        => 'auto',
    );
    my $avwapd_ov = Market::Overlays::AnchoredVWAPDavidOverlay->new( source => $avwapd_ind );
    my $pivotd_ind = Market::Indicators::PivotAnchorsDavid->new();
    my $pivotd_ov  = Market::Overlays::PivotAnchorsDavidOverlay->new( source => $pivotd_ind );

    my $avpd_ind = Market::Indicators::AnchoredVolumeProfileDavid->new(
        market_data => $market_data,
        mode        => 'auto',
    );
    my $avpd_ov = Market::Overlays::AnchoredVolumeProfileDavidOverlay->new( source => $avpd_ind );

    my $smc2_ind = Market::Indicators::SMCStructures2->new();
    my $smc2_ov  = Market::Overlays::SMCStructures2Overlay->new( source => $smc2_ind );

    # Liquidity David: reusar el ATR ya calculado por Kevin (si disponible)
    my $atr_existing = ($indicator_manager && $indicator_manager->can('get'))
        ? $indicator_manager->get('atr')
        : undef;
    my $liqd_ind = Market::Indicators::LiquidityDavid->new(
        market_data => $market_data,
        atr         => $atr_existing,   # puede ser undef; LiquidityDavid lo tolera
        zzmtf       => $zzmtf2d_ind,
        zzvp        => $zzvp2d_ind,
    );

    my $zzvp2d_ov   = Market::Overlays::ZigZagVP2DavidOverlay->new(   source => $zzvp2d_ind  );
    my $zzmtf2d_ov  = Market::Overlays::ZigZagMTF2DavidOverlay->new(  source => $zzmtf2d_ind );
    my $fibd_ov     = Market::Overlays::FibonacciDavidOverlay->new(   source => $fibd_ind    );
    my $liqd_ov     = Market::Overlays::LiquidityDavidOverlay->new(   source => $liqd_ind    );

    my $self = {
        canvas               => $canvas,
        market_data          => $market_data,
        indicator_manager    => $indicator_manager,
        engine_registry      => $engine_registry,      # <-- unica fuente de engines
        overlay_manager      => $args{overlay_manager} || Market::Core::OverlayManager->new(),
        overlay_settings     => $overlay_settings,
        replay_controller    => $args{replay_controller} || Market::Core::ReplayController->new(),
        timeframe_manager    => $args{timeframe_manager} || Market::Core::TimeframeManager->new(),
        viewport_controller  => $args{viewport_controller} || Market::Core::ViewportController->new(),
        price_panel          => $args{price_panel} || Market::Panels::PricePanel->new(),
        atr_panel            => $args{atr_panel}   || Market::Panels::ATRPanel->new(),
        price_scale          => $price_scale,
        atr_scale            => $atr_scale,

        pivotd_overlay => $pivotd_ov,
        pivotd_ind     => $pivotd_ind,
        avpd_overlay   => $avpd_ov,
        avpd_ind       => $avpd_ind,
        smc2_overlay   => $smc2_ov,
        smc2_ind       => $smc2_ind,

        # Overlays (render)
        liquidity_overlay    => $liquidity_overlay,
        structure_overlay    => $structure_overlay,
        fvg_overlay          => $fvg_overlay,
        orderblock_overlay   => $orderblock_overlay,
        volume_profile_overlay => $volume_profile_overlay,
        time_persistence_overlay => $time_persistence_overlay,
        anchored_vwap_overlay => $anchored_vwap_overlay,
        dsvwap_overlay       => $dsvwap_overlay,
        ghost_trails_overlay => $ghost_trails_overlay,
        fibonacci_overlay    => $fibonacci_overlay,

        avwapd_overlay => $avwapd_ov,
        avwapd_ind     => $avwapd_ind,

        supply_demand_overlay => $supply_demand_overlay,
        trend_channel_overlay    => $trend_channel_overlay,
        trailing_extremes_overlay => $trailing_extremes_overlay,
        premium_discount_overlay  => $premium_discount_overlay,
        mtf_levels_overlay        => $mtf_levels_overlay,
        zzmtf_overlay             => $zzmtf_overlay,

        # Tools Extra overlays
        zzvp2d_overlay   => $zzvp2d_ov,
        zzmtf2d_overlay  => $zzmtf2d_ov,
        fibd_overlay     => $fibd_ov,
        liqd_overlay     => $liqd_ov,
        # Tools Extra indicators (referencias para ToolsExtra toolbar)
        zzvp2d_ind       => $zzvp2d_ind,
        zzmtf2d_ind      => $zzmtf2d_ind,
        fibd_ind         => $fibd_ind,
        liqd_ind         => $liqd_ind,

        width                => $width,
        height               => $height,
        price_height         => $price_height,
        atr_height           => $atr_height,
        atr_ratio            => $atr_height / $height,
        time_axis_height     => $time_axis_height,
        max_visible_bars     => $max_visible_bars,
        current_visible_bars => $initial_visible,
        initial_visible_bars => $initial_visible,
        min_visible_bars     => 10,
        offset               => 0,
        x_shift              => 0,
        view_start           => 0,
        min_edge_bars        => 2,
        pending              => 0,
        crosshair_x          => undef,
        crosshair_y          => undef,
        auto_scale           => 1,
        atr_auto_scale       => 1,
        active_tf            => '1m',
        y_axis_zoom_drag     => 0,
        y_axis_zoom_target   => undef,
        y_axis_last_y        => undef,
        y_grab_active        => 0,
        y_grab_value         => undef,
        rmb_dragging         => 0,
        rmb_last_x           => undef,
        rmb_last_y           => undef,
        rmb_drag_accum       => 0,
        _auto_y_frozen       => 0,
        tf_viewport          => {},
        _zoom_frame          => 0,
        _zoom_hud_after      => undef,
        _replay_after        => undef,
        _replay_select_mode  => 0,
        wheel_event_counter  => 0,
        wheel_last_ts        => undef,
        wheel_last_event     => undef,
    };

    bless $self, $class;
    $self->{price_panel}->set_scale($price_scale);
    $self->{atr_panel}->set_scale($atr_scale);
    $self->{overlay_manager}->initialize() if $self->{overlay_manager} && $self->{overlay_manager}->can('initialize');
    $self->{replay_controller}->initialize() if $self->{replay_controller} && $self->{replay_controller}->can('initialize');

    # Fase 6 — GhostTrailPredictor + panel de demo
    {
        my $bin = dirname(File::Spec->rel2abs($0));
        my $out_dir = File::Spec->catdir($bin, 'output');
        my $models_path  = File::Spec->catfile($out_dir, 'models.json');
        my $norm_path    = File::Spec->catfile($out_dir, 'normalization_params.json');
        my $predictor;
        if (-f $models_path && -f $norm_path) {
            $predictor = Market::Concepts::DSVWAP::GhostTrailPredictor->new(
                models_path      => $models_path,
                norm_params_path => $norm_path,
                pip_factor       => 4,
            );
            $predictor->precompute_indicators($market_data);
        }
        $self->{ghost_predictor} = $predictor;
        $self->{ghost_prediction_panel} = Market::Panels::GhostTrailPredictionPanel->new(
            predictor        => $predictor,
            market_data      => $market_data,
            overlay_settings => $overlay_settings,
        );
    }

    $self->{indicator_manager}->register('anchored_vwap_david', $avwapd_ind, lazy_tf => 1);
    $self->{indicator_manager}->register('pivot_anchors_david', $pivotd_ind, lazy_tf => 1);
    $self->{indicator_manager}->register('anchored_vp_david', $avpd_ind, lazy_tf => 1);
    $self->{indicator_manager}->register('smc2', $smc2_ind, lazy_tf => 1);

    $self->{timeframe_manager}->initialize() if $self->{timeframe_manager} && $self->{timeframe_manager}->can('initialize');
    $self->{viewport_controller}->initialize() if $self->{viewport_controller} && $self->{viewport_controller}->can('initialize');
    $self->_register_overlays();
    if ($self->{timeframe_manager} && $self->{timeframe_manager}->can('set_active')) {
        my $initial_tf = $self->{market_data} ? $self->{market_data}->active_tf() : undef;
        $self->{timeframe_manager}->set_active($initial_tf) if defined $initial_tf;
    }
    $self->{candle_width} = $candle_width;

    # --- Tools Extra: registrar indicadores en indicator_manager (si existe) ---
    # lazy_tf: no se recalcula en cada cambio de temporalidad del chart
    # (cuesta ~5s). Se recomputan on-demand al activar el boton del toolbar
    # o si el overlay ya esta activo al cambiar de TF.
    if ( $self->{indicator_manager} && $self->{indicator_manager}->can('register') ) {
        $self->{indicator_manager}->register('zigzag_vp2_david',  $zzvp2d_ind, lazy_tf => 1);
        $self->{indicator_manager}->register('zigzag_mtf2_Dany', $zzmtf2d_ind, lazy_tf => 1);
        $self->{indicator_manager}->register('fibonacci_david',    $fibd_ind, lazy_tf => 1);
        $self->{indicator_manager}->register('liquidity_david',    $liqd_ind, lazy_tf => 1);
    }

    # --- Tools Extra: crear el toolbar (requiere que el parent widget exista) ---
    # El parent se pasa como arg desde market.pl; si no se pasa, el toolbar
    # no se construye (el resto del sistema funciona sin el).
    if ( my $toolbar_parent = $args{tools_extra_parent} ) {
        $self->{david_toolbar} = Market::ChartEngine::ToolsExtra->new(
            parent            => $toolbar_parent,
            overlay_manager   => $self->{overlay_manager},
            chart_engine      => $self,
            overlay_settings  => $overlay_settings,
            replay_controller => $self->{replay_controller},
            indicator_refs    => {
                zigzag_vp2  => $zzvp2d_ind,
                zigzag_mtf2 => $zzmtf2d_ind,
                fibonacci   => $fibd_ind,
                liquidity   => $liqd_ind,
                avwap       => $avwapd_ind,
                pivot_anchors => $pivotd_ind,   
                anchored_vp   => $avpd_ind,     
                smc2          => $smc2_ind,
            },
            overlay_refs => {
                zigzag_vp2  => $zzvp2d_ov,
                zigzag_mtf2 => $zzmtf2d_ov,
                fibonacci   => $fibd_ov,
                liquidity   => $liqd_ov,
                avwap       => $avwapd_ov,
                pivot_anchors => $pivotd_ov,    
                anchored_vp   => $avpd_ov,      
                smc2          => $smc2_ov,
            },
        );
        $self->{david_toolbar}->build();
    }

    # Carga inicial de datos: construye la cache de analisis una sola vez, para
    # que el primer (y todos los) render() solo consuma resultados cacheados.
    $self->rebuild_analysis_cache();
    $self->_replay_sync_controls();
    return $self;
}

# _build_legacy_engine_registry($indicator_manager, %args) -> $registry
# Retrocompatibilidad: construye un EngineRegistry con los engines pasados
# individualmente como args a new(), preservando el orden de dependencias.
# Solo se invoca si NO se inyecta un engine_registry desde market.pl.
sub _sync_infra_state {
    my ($self) = @_;
    return unless $self->{viewport_controller};
    $self->{viewport_controller}->set_window(
        start_index => $self->{start_idx},
        end_index   => $self->{end_idx},
        visible_bars => $self->{visible_bars},
        offset      => $self->{offset},
        x_shift     => $self->{x_shift},
    ) if $self->{viewport_controller}->can('set_window');

    if ($self->{timeframe_manager} && $self->{timeframe_manager}->can('set_active')) {
        my $tf = $self->{active_tf} || $self->{market_data}->active_tf();
        $self->{timeframe_manager}->set_active($tf) if defined $tf;
    }

    return $self;
}


sub resize {
    my ($self, $width, $height) = @_;
    return unless defined $width && defined $height;
    return unless $width > 0 && $height > 0;
    return if $self->{width} == $width && $self->{height} == $height;

    my $atr_height = int($height * ($self->{atr_ratio} || 0.14));
    $atr_height = 55 if $atr_height < 55;
    my $atr_max = int($height * 0.16);
    $atr_height = $atr_max if $atr_height > $atr_max;
    my $tah = $self->{time_axis_height} || 42;
    my $price_height = $height - $atr_height - $tah;
    return unless $price_height > 0;

    $self->{width}        = $width;
    $self->{height}       = $height;
    $self->{atr_height}   = $atr_height;
    $self->{price_height} = $price_height;

    $self->{price_scale}{width}  = $width;
    $self->{price_scale}{height} = $price_height;

    $self->{atr_scale}{width}    = $width;
    $self->{atr_scale}{height}   = $atr_height;
    $self->{atr_scale}{y_offset} = $price_height;

    my $visible = $self->{current_visible_bars} || $self->{initial_visible_bars};
    my $pw = ($width || 0) - ($self->{price_scale}{y_axis_strip_w} || 66);
    $self->_apply_candle_width(($pw > 0 ? $pw : $width) / $visible) if $visible;

    # El x_shift esta en pixeles respecto al ancho de vela anterior; tras cambiar
    # el ancho deja de ser valido, asi que se descarta (se recalcula al hacer zoom).
    $self->{x_shift} = 0;

    $self->request_render();
}

# ── Calculo de ventana ────────────────────────────────────────────────────────

sub round {
    my ($self, $value) = @_;
    return undef unless defined $value;
    return int($value + ($value >= 0 ? 0.5 : -0.5));
}

# ---------------------------------------------------------------------------
# Modulos del mismo paquete (split por responsabilidad / SRP).
# Misma API publica de Market::ChartEngine; sin cambio de comportamiento.
# ---------------------------------------------------------------------------
require 'Market/ChartEngine/Events.pm';
require 'Market/ChartEngine/Controls.pm';
require 'Market/ChartEngine/Replay.pm';
require 'Market/ChartEngine/Geometry.pm';
require 'Market/ChartEngine/Render.pm';
require 'Market/ChartEngine/Analysis.pm';
require 'Market/ChartEngine/Crosshair.pm';
require 'Market/ChartEngine/Zoom.pm';
require 'Market/ChartEngine/Interaction.pm';

1;