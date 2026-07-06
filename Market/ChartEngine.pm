package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine
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
use Market::Core::EventBus;
use Market::Core::OverlayManager;
use Market::Core::OverlaySettings;
use Market::Core::ReplayController;
use Market::Core::TimeframeManager;
use Market::Core::ViewportController;
use Market::Core::YAxisHitTest;
use Market::Core::VerticalScaleZoom;
use Market::Core::ATRPanelZoom;
use Market::Indicators::Liquidity;
use Market::Structure::StructureEngine;
use Market::Concepts::FVGEngine;
use Market::Overlays::LiquidityOverlay;
use Market::Overlays::StructureOverlay;
use Market::Overlays::FVGOverlay;

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

    my $atr_indicator = undef;
    if ($indicator_manager && $indicator_manager->can('get')) {
        $atr_indicator = $indicator_manager->get('atr');
    }
    my $liquidity_engine = $args{liquidity_engine} || Market::Indicators::Liquidity->new(
        atr_indicator => $atr_indicator,
    );
    my $structure_engine = $args{structure_engine} || Market::Structure::StructureEngine->new(
        liquidity => $liquidity_engine,
    );
    my $fvg_engine = $args{fvg_engine} || Market::Concepts::FVGEngine->new();
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

    my $self = {
        canvas               => $canvas,
        market_data          => $market_data,
        indicator_manager    => $indicator_manager,
        event_bus            => $args{event_bus} || Market::Core::EventBus->new(),
        overlay_manager      => $args{overlay_manager} || Market::Core::OverlayManager->new(),
        overlay_settings     => $overlay_settings,
        replay_controller    => $args{replay_controller} || Market::Core::ReplayController->new(),
        timeframe_manager    => $args{timeframe_manager} || Market::Core::TimeframeManager->new(),
        viewport_controller  => $args{viewport_controller} || Market::Core::ViewportController->new(),
        price_panel          => $args{price_panel} || Market::Panels::PricePanel->new(),
        atr_panel            => $args{atr_panel}   || Market::Panels::ATRPanel->new(),
        price_scale          => $price_scale,
        atr_scale            => $atr_scale,
        liquidity_engine     => $liquidity_engine,
        structure_engine     => $structure_engine,
        fvg_engine           => $fvg_engine,
        liquidity_overlay    => $liquidity_overlay,
        structure_overlay    => $structure_overlay,
        fvg_overlay          => $fvg_overlay,
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
        # Desplazamiento horizontal sub-pixel (px) para anclar el zoom con
        # precision exacta sin acumular desfase. Se propaga a las escalas en
        # render() y se recalcula en cada zoom. Se resetea en reset/resize/TF.
        x_shift              => 0,
        # Indice logico del borde izquierdo del viewport (lo calcula
        # compute_window). Puede ser negativo cuando hay whitespace a la izquierda.
        view_start           => 0,
        # Velas reales que SIEMPRE deben permanecer visibles en los extremos de
        # scroll (estilo TradingView: la vista nunca se vacia por completo). Se
        # usa para los topes de offset en compute_window(), en ambos modos.
        min_edge_bars        => 2,
        pending              => 0,
        crosshair_x          => undef,
        crosshair_y          => undef,
        auto_scale           => 1,
        atr_auto_scale       => 1,
        active_tf            => '1m',
        # ESCALAYV2: drag en franja del eje Y (precios o ATR).
        y_axis_zoom_drag     => 0,
        y_axis_zoom_target   => undef,
        y_axis_last_y        => undef,
        y_grab_active        => 0,
        y_grab_value         => undef,
        # Pan con boton derecho: explorar el grafico sin cambiar AUTO/MANUAL.
        rmb_dragging         => 0,
        rmb_last_x           => undef,
        rmb_last_y           => undef,
        rmb_drag_accum       => 0,
        # En AUTO, tras pan vertical con RMB se conserva el desplazamiento Y
        # hasta reset, cambio de TF o volver a forzar AUTO con la tecla A.
        _auto_y_frozen       => 0,
        # Viewport independiente por temporalidad (misma logica, estado propio).
        tf_viewport          => {},
        # Durante zoom con rueda: render del grafico sin redibujar HUD (evita parpadeo).
        _zoom_frame          => 0,
        _zoom_hud_after      => undef,
        _replay_after        => undef,
        wheel_event_counter  => 0,
        wheel_last_ts        => undef,
        wheel_last_event     => undef,
    };

    bless $self, $class;
    $self->{price_panel}->set_scale($price_scale);
    $self->{atr_panel}->set_scale($atr_scale);
    $self->{event_bus}->initialize() if $self->{event_bus} && $self->{event_bus}->can('initialize');
    $self->{overlay_manager}->initialize() if $self->{overlay_manager} && $self->{overlay_manager}->can('initialize');
    $self->{replay_controller}->initialize() if $self->{replay_controller} && $self->{replay_controller}->can('initialize');
    $self->{timeframe_manager}->initialize() if $self->{timeframe_manager} && $self->{timeframe_manager}->can('initialize');
    $self->{viewport_controller}->initialize() if $self->{viewport_controller} && $self->{viewport_controller}->can('initialize');
    $self->_register_overlays();
    if ($self->{timeframe_manager} && $self->{timeframe_manager}->can('set_active')) {
        my $initial_tf = $self->{market_data} ? $self->{market_data}->active_tf() : undef;
        $self->{timeframe_manager}->set_active($initial_tf) if defined $initial_tf;
    }
    $self->{candle_width} = $candle_width;
    # Carga inicial de datos: construye la cache de analisis una sola vez, para
    # que el primer (y todos los) render() solo consuma resultados cacheados.
    $self->rebuild_analysis_cache();
    return $self;
}

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

    if ($self->{event_bus} && $self->{event_bus}->can('publish')) {
        $self->{event_bus}->publish('viewport_changed', $self->{viewport_controller}->get_state())
            if $self->{viewport_controller}->can('get_state');
        $self->{event_bus}->publish('timeframe_changed', $self->{active_tf} || $self->{market_data}->active_tf())
            if $self->{market_data};
        $self->{event_bus}->publish('mouse_move', $self->{crosshair_x}, $self->{crosshair_y})
            if defined $self->{crosshair_x} || defined $self->{crosshair_y};
        $self->{event_bus}->publish('zoom_changed', $self->{current_visible_bars})
            if defined $self->{current_visible_bars};
    }
    return $self;
}

# ── Eventos ───────────────────────────────────────────────────────────────────

sub _wheel_debug_enabled {
    my ($self) = @_;
    return 1 if $Market::ChartEngine::DEBUG_WHEEL;
    return 0 unless defined $ENV{MARKET_WHEEL_DEBUG};
    return $ENV{MARKET_WHEEL_DEBUG} =~ /^(1|true|yes|on)$/i ? 1 : 0;
}

sub _wheel_debug_path {
    my ($self) = @_;
    my $path = $ENV{MARKET_WHEEL_LOG};
    return defined $path && $path ne '' ? $path : undef;
}

sub _wheel_debug_log {
    my ($self, $message) = @_;
    return unless $self && $self->_wheel_debug_enabled();
    return unless defined $message && $message ne '';

    my $path = $self->_wheel_debug_path();
    if (defined $path) {
        open my $fh, '>>', $path or do {
            print STDERR "[wheel-debug] unable to open $path: $!\n";
            return;
        };
        print {$fh} $message;
        close $fh;
    }
    else {
        print STDERR $message;
    }
}

sub _wheel_debug_value {
    my ($self, $value) = @_;
    return defined $value ? $value : 'undef';
}

# _dbg_wheel($tag, %kv)
# Log de diagnostico a STDERR o MARKET_WHEEL_LOG. Cada linea trae timestamp de
# alta resolucion + tag + pares clave=valor para reconstruir un giro de rueda.
sub _dbg_wheel {
    my ($self, $tag, %kv) = @_;
    return unless $self && $self->_wheel_debug_enabled();

    my $ts = sprintf('%.6f', Time::HiRes::time());
    my $line = join(' ', map {
        "$_=" . $self->_wheel_debug_value($kv{$_})
    } sort keys %kv);

    $self->_wheel_debug_log("[WHEEL $ts] $tag $line\n");
}

sub _disable_canvas_native_wheel_scroll {
    my ($self, $canvas) = @_;
    return unless $canvas;

    # En X11 la rueda llega como Button-4/5 y la clase Tk::Canvas puede ejecutar
    # yview scroll. Este canvas no debe desplazarse nunca en Y: todo el viewport
    # lo maneja ChartEngine.
    for my $seq (
        '<Button-4>', '<Button-5>',
        '<Control-Button-4>', '<Control-Button-5>',
        '<MouseWheel>', '<Control-MouseWheel>',
    ) {
        eval { $canvas->bind('Canvas', $seq, '') };
    }

    eval {
        my @tags = $canvas->bindtags;
        my @filtered = grep { defined $_ && $_ ne 'Canvas' } @tags;
        $canvas->bindtags(\@filtered) if @filtered != @tags;
    };
}

sub _canvas_yview_first {
    my ($self, $canvas) = @_;
    return undef unless $canvas;
    my @view = eval { $canvas->yview };
    return @view ? $view[0] : undef;
}

sub _reset_canvas_yview {
    my ($self, $canvas) = @_;
    return unless $canvas;
    eval { $canvas->yview('moveto', 0) };
}

sub _dispatch_wheel_event {
    my ($self, $canvas, $event_name, $dir, $ctrl) = @_;
    return unless $self && $canvas;

    $self->_disable_canvas_native_wheel_scroll($canvas);
    my $yview_before = $self->_canvas_yview_first($canvas);

    my $x_evt = eval { $canvas->XEvent->x };
    my $y_evt = eval { $canvas->XEvent->y };
    my $x_before = $self->{crosshair_x};
    my $y_before = $self->{crosshair_y};
    my $canvas_w = eval { $canvas->width };
    my $canvas_h = eval { $canvas->height };

    $self->_dbg_wheel('EVT',
        event              => $event_name,
        dir                => $dir,
        ctrl               => $ctrl ? 1 : 0,
        ev_x               => $x_evt,
        ev_y               => $y_evt,
        crosshair_x_before => $x_before,
        crosshair_y_before => $y_before,
        self_w             => $self->{width},
        self_h             => $self->{height},
        canvas_w           => $canvas_w,
        canvas_h           => $canvas_h,
        yview_before       => $yview_before,
        offset_before      => $self->{offset},
        visible_before     => $self->{current_visible_bars},
        x_shift_before     => $self->{x_shift},
        view_start_before  => $self->{view_start},
    );

    $self->{crosshair_x} = defined $x_evt ? $x_evt : $self->{crosshair_x};
    $self->{crosshair_y} = defined $y_evt ? $y_evt : $self->{crosshair_y};

    my $now = time();
    my $dt = defined $self->{wheel_last_ts} ? ($now - $self->{wheel_last_ts}) : 0;
    $self->{wheel_event_counter} = 0 unless defined $self->{wheel_event_counter};
    $self->{wheel_event_counter}++;
    $self->{wheel_last_ts} = $now;
    $self->{wheel_last_event} = $event_name;

    if ($self->_wheel_debug_enabled()) {
        my $x_after = $self->{crosshair_x};
        my $y_after = $self->{crosshair_y};
        my $price_strip = defined $x_after && defined $y_after ? ($self->_in_price_y_axis_strip($x_after, $y_after) ? 1 : 0) : 'undef';
        my $atr_strip = defined $x_after && defined $y_after ? ($self->_in_atr_y_axis_strip($x_after, $y_after) ? 1 : 0) : 'undef';
        $self->_wheel_debug_log(sprintf(
            "WHEEL_ASSIGN ts=%.6f event=%s seq=%d dt=%.6f dir=%s ctrl=%s x_evt=%s y_evt=%s crosshair_before=(%s,%s) crosshair_after=(%s,%s) canvas=(%s,%s) self=(%s,%s) price_strip=%s atr_strip=%s\n",
            $now,
            defined $event_name ? $event_name : 'unknown',
            $self->{wheel_event_counter},
            $dt,
            $self->_wheel_debug_value($dir),
            $ctrl ? 1 : 0,
            $self->_wheel_debug_value($x_evt),
            $self->_wheel_debug_value($y_evt),
            $self->_wheel_debug_value($x_before),
            $self->_wheel_debug_value($y_before),
            $self->_wheel_debug_value($x_after),
            $self->_wheel_debug_value($y_after),
            $self->_wheel_debug_value($canvas_w),
            $self->_wheel_debug_value($canvas_h),
            $self->_wheel_debug_value($self->{width}),
            $self->_wheel_debug_value($self->{height}),
            $price_strip,
            $atr_strip,
        ));
    }

    $self->_route_wheel_zoom($dir, $ctrl, $event_name, $self->{wheel_event_counter}, $dt);
    $self->_reset_canvas_yview($canvas);
    my $yview_after = $self->_canvas_yview_first($canvas);

    $self->_dbg_wheel('AFTER',
        event            => $event_name,
        dir              => $dir,
        ctrl             => $ctrl ? 1 : 0,
        offset_after     => $self->{offset},
        visible_after    => $self->{current_visible_bars},
        x_shift_after    => $self->{x_shift},
        view_start_after => $self->{view_start},
        yview_after      => $yview_after,
    );
}

sub _bind_all_canvas {
    my ($self, $canvas) = @_;
    return unless $canvas;
    $self->_disable_canvas_native_wheel_scroll($canvas);

    # <Configure> se dispara cuando el canvas cambia de tamano (maximizar,
    # pantalla completa, redimensionar la ventana). Adaptamos las escalas al
    # nuevo ancho/alto reales del widget para que el grafico ocupe todo el area.
    $canvas->Tk::bind('<Configure>' => [sub {
        my ($w, $width, $height) = @_;
        $self->resize($width, $height);
    }, Tk::Ev('w'), Tk::Ev('h')]);

    $canvas->Tk::bind('<Motion>' => sub {
        $self->_on_mouse_move($canvas->XEvent->x, $canvas->XEvent->y);
    });
    # Drag con boton izquierdo: pan en el grafico O zoom vertical en la franja del
    # eje Y de precios (misma zona que ESCALAY), detectado por coordenadas.
    $canvas->Tk::bind('<Button-1>' => sub {
        my $x = $canvas->XEvent->x;
        my $y = $canvas->XEvent->y;
        if ($self->_in_price_y_axis_strip($x, $y)) {
            $self->{y_axis_zoom_drag}   = 1;
            $self->{y_axis_zoom_target} = 'price';
            $self->{y_axis_last_y}      = $y;
            $self->{h_dragging}         = 0;
            if ($self->{auto_scale}) {
                $self->{auto_scale} = 0;
                $self->render();
            }
            $self->{price_scale}->{scale_drag_active} = 1 if $self->{price_scale};
            $self->_ensure_scale_covers_data('price');
            return;
        }
        if ($self->_in_atr_y_axis_strip($x, $y)) {
            $self->{y_axis_zoom_drag}   = 1;
            $self->{y_axis_zoom_target} = 'atr';
            $self->{y_axis_last_y}      = $y;
            $self->{h_dragging}         = 0;
            $self->{atr_auto_scale}     = 0;
            if ($self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2) {
                Market::Core::ATRPanelZoom::fit_to_data(
                    $self->{atr_scale}, @{$self->{_cached_atr_y}},
                );
            }
            $self->{atr_scale}->{scale_drag_active} = 1 if $self->{atr_scale};
            return;
        }
        $self->{y_axis_zoom_drag}   = 0;
        $self->{y_axis_zoom_target} = undef;
        $self->{h_dragging}       = 1;
        # Pan vertical del precio solo si el gesto empieza en el panel de precios
        # (el ATR es un panel independiente, estilo TradingView).
        $self->{pan_vertical_enabled} = $self->_in_price_panel($y) ? 1 : 0;
        # Clic en el area del grafico NO cambia AUTO/MANUAL (solo tecla A o franja Y).
        $self->{last_mouse_x} = $x;
        $self->{last_mouse_y} = $y;
        $self->{drag_accum}   = 0;
        $self->{y_grab_active} = 0;
        $self->{y_grab_value}  = undef;
    });
    $canvas->Tk::bind('<B1-Motion>' => sub {
        if ($self->{y_axis_zoom_drag}) {
            my $y  = $canvas->XEvent->y;
            my $y0 = defined $self->{y_axis_last_y} ? $self->{y_axis_last_y} : $y;
            my $dy = $y - $y0;
            $self->_y_axis_scale_drag($y, $dy, $self->{y_axis_zoom_target} || 'price');
            $self->{y_axis_last_y} = $y;
            return;
        }
        return unless $self->{h_dragging};
        my $x  = $canvas->XEvent->x;
        my $y  = $canvas->XEvent->y;
        my $dx = $x - $self->{last_mouse_x};
        my $dy = $y - $self->{last_mouse_y};   # > 0 al arrastrar hacia abajo
        $self->{last_mouse_x} = $x;
        $self->{last_mouse_y} = $y;
        # Boton izquierdo: pan horizontal siempre; vertical solo en panel de precios.
        my $allow_v = $self->{pan_vertical_enabled} ? 1 : 0;
        $self->_pan_drag($dx, $dy, $allow_v, 'drag_accum');
    });
    $canvas->Tk::bind('<ButtonRelease-1>' => sub {
        $self->{h_dragging}       = 0;
        $self->{y_axis_zoom_drag}   = 0;
        $self->{y_axis_zoom_target} = undef;
        $self->{y_axis_last_y}      = undef;
        $self->{y_grab_active}      = 0;
        $self->{y_grab_value}       = undef;
        if ($self->{price_scale}) {
            $self->{price_scale}->{scale_drag_active} = 0;
        }
        if ($self->{atr_scale}) {
            $self->{atr_scale}->{scale_drag_active} = 0;
        }
    });

    # Boton derecho: pan horizontal + vertical en el area del grafico (AUTO o MANUAL).
    $canvas->Tk::bind('<Button-3>' => sub {
        my $x = $canvas->XEvent->x;
        my $y = $canvas->XEvent->y;
        return if $self->_in_price_y_axis_strip($x, $y);
        return if $self->_in_atr_y_axis_strip($x, $y);
        $self->{rmb_dragging}   = 1;
        $self->{pan_vertical_enabled} = $self->_in_price_panel($y) ? 1 : 0;
        $self->{rmb_last_x}     = $x;
        $self->{rmb_last_y}     = $y;
        $self->{rmb_drag_accum} = 0;
    });
    $canvas->Tk::bind('<B3-Motion>' => sub {
        return unless $self->{rmb_dragging};
        my $x  = $canvas->XEvent->x;
        my $y  = $canvas->XEvent->y;
        my $dx = $x - (defined $self->{rmb_last_x} ? $self->{rmb_last_x} : $x);
        my $dy = $y - (defined $self->{rmb_last_y} ? $self->{rmb_last_y} : $y);
        $self->{rmb_last_x} = $x;
        $self->{rmb_last_y} = $y;
        my $allow_v = $self->{pan_vertical_enabled} ? 1 : 0;
        $self->_pan_drag($dx, $dy, $allow_v, 'rmb_drag_accum');
    });
    $canvas->Tk::bind('<ButtonRelease-3>' => sub {
        $self->{rmb_dragging}   = 0;
        $self->{rmb_last_x}     = undef;
        $self->{rmb_last_y}     = undef;
        $self->{rmb_drag_accum} = 0;
    });

    # Rueda del mouse X11/Linux: enrutada segun panel bajo el cursor.
    # IMPORTANTE: Tk::Canvas trae un binding de CLASE por defecto para
    # <Button-4>/<Button-5> que hace `yview scroll` (scroll vertical nativo,
    # usado porque X11 simula la rueda con clics de boton 4/5). Como nuestro
    # binding de instancia se ejecuta ANTES pero NO detiene la cadena de
    # bindtags, ese scroll de clase se ejecutaba igualmente despues del
    # nuestro, desplazando verticalmente todo el canvas (solo se veia en
    # Linux/X11; en Windows la rueda llega como <MouseWheel> sobre la
    # MainWindow y nunca toca ese binding de clase del Canvas).
    # Tk::break corta la propagacion al bindtag de clase y elimina el salto Y.
    $canvas->Tk::bind('<Button-4>' => sub {
        $self->_dispatch_wheel_event($canvas, 'Button-4', -1, 0);
        return Tk::break;
    });
    $canvas->Tk::bind('<Button-5>' => sub {
        $self->_dispatch_wheel_event($canvas, 'Button-5', +1, 0);
        return Tk::break;
    });
    $canvas->Tk::bind('<Control-Button-4>' => sub {
        $self->_dispatch_wheel_event($canvas, 'Control-Button-4', -1, 1);
        return Tk::break;
    });
    $canvas->Tk::bind('<Control-Button-5>' => sub {
        $self->_dispatch_wheel_event($canvas, 'Control-Button-5', +1, 1);
        return Tk::break;
    });
}

# bind_events($main_window)
# Recibe la MainWindow de market.pl para enlazar KeyPress directamente en ella.
# En Perl/Tk los numeros 1/2/3 como bindings de teclado requieren KeyPress-1,
# porque <1> significa "boton 1 del mouse".
sub bind_events {
    my ($self, $main_window) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;

    my $mw = $main_window || $canvas->MainWindow();

    $self->_bind_all_canvas($canvas);

    # Rueda del mouse (Windows/macOS) — enrutada segun panel bajo el cursor.
    $mw->bind('<MouseWheel>', [sub {
        my ($w, $delta) = @_;
        my $canvas = $self->{canvas};
        $self->_dispatch_wheel_event($canvas, 'MouseWheel', $delta > 0 ? -1 : +1, 0);
    }, Tk::Ev('D')]);
    $mw->bind('<Control-MouseWheel>', [sub {
        my ($w, $delta) = @_;
        my $canvas = $self->{canvas};
        $self->_dispatch_wheel_event($canvas, 'Control-MouseWheel', $delta > 0 ? -1 : +1, 1);
    }, Tk::Ev('D')]);

    $mw->bind('<Left>'  => sub { $self->_scroll_offset(1);  });
    $mw->bind('<Right>' => sub { $self->_scroll_offset(-1); });

    $mw->bind('<a>' => sub {
        $self->{auto_scale} = $self->{auto_scale} ? 0 : 1;
        $self->{_auto_y_frozen} = 0 if $self->{auto_scale};
        $self->render();
    });
    $mw->bind('<r>' => sub { $self->reset_view(); });

    # FIX: <KeyPress-N> para teclas numericas (no <N> que es el boton N del mouse)
    # Orden de teclas = orden del spec: 1m,5m,15m,1h,2h,4h,D,W.
    $mw->bind('<KeyPress-1>' => sub { $self->set_timeframe('1m');  });
    $mw->bind('<KeyPress-2>' => sub { $self->set_timeframe('5m');  });
    $mw->bind('<KeyPress-3>' => sub { $self->set_timeframe('15m'); });
    $mw->bind('<KeyPress-4>' => sub { $self->set_timeframe('1H');  });
    $mw->bind('<KeyPress-5>' => sub { $self->set_timeframe('2H');  });
    $mw->bind('<KeyPress-6>' => sub { $self->set_timeframe('4H');  });
    $mw->bind('<KeyPress-7>' => sub { $self->set_timeframe('1D');  });
    $mw->bind('<KeyPress-8>' => sub { $self->set_timeframe('1W');  });

    # ── Replay (spec: Inicio, Play, Pause, Step +/-, Fast Forward, Exit) ────────
    $mw->bind('<KeyPress-p>' => sub { $self->_replay_enter(); });
    $mw->bind('<KeyPress-P>' => sub { $self->_replay_enter(); });
    $mw->bind('<space>'      => sub { $self->_replay_toggle_play(); });
    $mw->bind('<KeyPress-bracketright>' => sub { $self->_replay_step_forward(); });
    $mw->bind('<KeyPress-bracketleft>'  => sub { $self->_replay_step_backward(); });
    $mw->bind('<Shift-KeyPress-bracketright>' => sub { $self->_replay_fast_forward(); });
    $mw->bind('<Escape>' => sub { $self->_replay_exit(); });

    $mw->focus();
}

# build_control_panel($main_window)
# Barra Perl/Tk con controles de Replay (spec §3) y toggles de overlays (spec §4.5).
sub build_control_panel {
    my ($self, $main_window) = @_;
    return unless $main_window;

    my $bg = '#1e222d';
    my $fg = '#e0e3ea';

    my $panel = $main_window->Frame(-background => $bg)->pack(
        -side => 'top', -fill => 'x', -padx => 4, -pady => 2,
    );

    my $replay_frame = $panel->Labelframe(
        -text      => ' Replay ',
        -background => $bg,
        -fg        => $fg,
        -font      => 'Helvetica 9 bold',
    )->pack(-side => 'left', -padx => 4);

    my @replay_btns = (
        ['Inicio',  sub { $self->_replay_enter(); }],
        ['Play/Pausa', sub { $self->_replay_toggle_play(); }],
        ['<<',      sub { $self->_replay_step_backward(); }],
        ['>>',      sub { $self->_replay_step_forward(); }],
        ['FF >>',   sub { $self->_replay_fast_forward(); }],
        ['Salir',   sub { $self->_replay_exit(); }],
    );
    for my $btn (@replay_btns) {
        $replay_frame->Button(
            -text     => $btn->[0],
            -command  => $btn->[1],
            -background => '#2a2e39',
            -foreground => $fg,
            -activebackground => '#363a45',
            -font     => 'Helvetica 8',
            -padx     => 6,
            -pady     => 2,
        )->pack(-side => 'left', -padx => 2, -pady => 2);
    }

    my $overlay_frame = $panel->Labelframe(
        -text      => ' Indicators ',
        -background => $bg,
        -fg        => $fg,
        -font      => 'Helvetica 9 bold',
    )->pack(-side => 'left', -padx => 8, -fill => 'x');

    $self->{_overlay_vars} = {};
    my $settings = $self->{overlay_settings};
    my $schema = $settings && $settings->can('schema') ? $settings->schema() : [];

    for my $category (@$schema) {
        my $cat_label = $category->{label} || $category->{id};
        my $button = $overlay_frame->Menubutton(
            -text       => $cat_label,
            -relief     => 'flat',
            -background => '#2a2e39',
            -foreground => $fg,
            -activebackground => '#363a45',
            -activeforeground => '#ffffff',
            -font       => 'Helvetica 8',
            -padx       => 7,
            -pady       => 2,
        )->pack(-side => 'left', -padx => 2, -pady => 2);

        my $menu = $button->Menu(
            -tearoff => 0,
            -background => '#1e222d',
            -foreground => $fg,
            -activebackground => '#363a45',
            -activeforeground => '#ffffff',
        );
        $button->configure(-menu => $menu);

        for my $opt (@{ $category->{options} || [] }) {
            my ($key, $label) = @$opt;
            $self->{_overlay_vars}{$key} = $settings->enabled($key);
            $menu->checkbutton(
                -label      => $label,
                -variable   => \$self->{_overlay_vars}{$key},
                -selectcolor => '#2a2e39',
                -command    => sub {
                    $self->set_overlay_option($key, $self->{_overlay_vars}{$key});
                },
            );
        }
    }

    return $panel;
}

# set_overlay_option($key, $flag)
sub set_overlay_option {
    my ($self, $key, $enabled) = @_;
    return unless $self->{overlay_settings};
    $self->{overlay_settings}->set($key, $enabled);
    $self->{overlay_settings}->save() if $self->{overlay_settings}->can('save');
    $self->_sync_overlay_layer_state();
    $self->render();
    return $self;
}

# set_overlay_enabled($name, $flag)
sub set_overlay_enabled {
    my ($self, $name, $enabled) = @_;
    return unless $self->{overlay_manager};
    if ($enabled) {
        $self->{overlay_manager}->enable($name) if $self->{overlay_manager}->can('enable');
    }
    else {
        $self->{overlay_manager}->disable($name) if $self->{overlay_manager}->can('disable');
    }
    $self->render();
    return $self;
}

sub _sync_overlay_layer_state {
    my ($self) = @_;
    return unless $self->{overlay_manager} && $self->{overlay_settings};
    my $s = $self->{overlay_settings};

    my $structure_on =
        $s->enabled('show_swing_high') || $s->enabled('show_swing_low')
        || $s->enabled('show_hh') || $s->enabled('show_hl')
        || $s->enabled('show_lh') || $s->enabled('show_ll')
        || $s->enabled('show_bos') || $s->enabled('show_choch')
        || $s->enabled('show_eqh') || $s->enabled('show_eql')
        || $s->enabled('show_internal_zigzag') || $s->enabled('show_external_zigzag')
        || $s->enabled('show_internal_swings') || $s->enabled('show_external_swings');

    my $liquidity_on =
        $s->enabled('show_liquidity_levels')
        || $s->enabled('show_internal_liquidity') || $s->enabled('show_external_liquidity')
        || $s->enabled('show_sweeps') || $s->enabled('show_grabs') || $s->enabled('show_runs');

    my $fvg_on = $s->enabled('show_fvg');

    for my $pair ([structure => $structure_on], [liquidity => $liquidity_on], [fvg => $fvg_on]) {
        my ($name, $on) = @$pair;
        if ($on) {
            $self->{overlay_manager}->enable($name) if $self->{overlay_manager}->can('enable');
        }
        else {
            $self->{overlay_manager}->disable($name) if $self->{overlay_manager}->can('disable');
        }
    }
    return $self;
}

# ── Replay ────────────────────────────────────────────────────────────────────

sub _cancel_replay_timer {
    my ($self) = @_;
    if ($self->{_replay_after} && $self->{canvas}) {
        eval { $self->{canvas}->afterCancel($self->{_replay_after}); };
        $self->{_replay_after} = undef;
    }
    return $self;
}

sub _replay_sync_viewport {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->is_active() && $self->{market_data};
    my $total = $self->{market_data}->size();
    my $idx   = $rc->{current_index} // 0;
    $self->{offset} = $total - 1 - $idx;
    $self->{offset} = 0 if $self->{offset} < 0;
    return $self;
}

sub _replay_apply {
    my ($self) = @_;
    $self->_replay_sync_viewport();
    if ($self->{indicator_manager} && $self->{indicator_manager}->can('rebuild_all')) {
        $self->{indicator_manager}->rebuild_all($self->{market_data});
    }
    $self->invalidate_analysis_cache();
    $self->rebuild_analysis_cache();
    $self->render();
    return $self;
}

sub _replay_enter {
    my ($self) = @_;
    return unless $self->{market_data} && $self->{replay_controller};
    my $total = $self->{market_data}->size();
    return unless $total > 0;

    my $idx = $self->{crosshair_idx};
    if (!defined $idx) {
        my ($start, $end) = $self->compute_window();
        $idx = $end;
    }
    $idx = $total - 1 if $idx >= $total;

    $self->_cancel_replay_timer();
    $self->{replay_controller}->enter_replay($idx, $total);
    $self->_replay_apply();
}

sub _replay_exit {
    my ($self) = @_;
    return unless $self->{replay_controller};
    $self->_cancel_replay_timer();
    $self->{replay_controller}->exit_replay();
    $self->invalidate_analysis_cache();
    $self->rebuild_analysis_cache();
    $self->render();
}

sub _replay_toggle_play {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->is_active();

    if ($rc->{playing}) {
        $rc->pause();
        $self->_cancel_replay_timer();
        $self->render();
        return;
    }

    my $total = $self->{market_data}->size();
    return unless $total > 0;
    return if $rc->{current_index} >= $total - 1;

    $rc->play();
    $self->_replay_schedule_tick();
}

sub _replay_step_forward {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->is_active();

    my $total = $self->{market_data}->size();
    $rc->pause();
    $self->_cancel_replay_timer();
    $rc->step_forward($total);
    $self->_replay_apply();
}

sub _replay_step_backward {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->is_active();

    $rc->pause();
    $self->_cancel_replay_timer();
    $rc->step_backward();
    $self->_replay_apply();
}

sub _replay_fast_forward {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->is_active();

    my $total = $self->{market_data}->size();
    $rc->pause();
    $self->_cancel_replay_timer();
    $rc->fast_forward(10, $total);
    $self->_replay_apply();
}

sub _replay_schedule_tick {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->{playing} && $self->{canvas};

    my $total = $self->{market_data}->size();
    if ($total <= 0 || $rc->{current_index} >= $total - 1) {
        $rc->stop();
        $self->render();
        return;
    }

    my $speed = $rc->{speed} || 1;
    my $delay = int(400 / $speed);
    $delay = 16 if $delay < 16;

    $self->{_replay_after} = $self->{canvas}->after($delay, sub {
        my $r = $self->{replay_controller};
        return unless $r && $r->{playing};

        my $n = $self->{market_data}->size();
        if ($n <= 0 || $r->{current_index} >= $n - 1) {
            $r->stop();
            $self->render();
            return;
        }

        $r->step_forward($n);
        $self->_replay_apply();
        $self->_replay_schedule_tick();
    });
}

# ── Redimensionado ────────────────────────────────────────────────────────────

# resize($width, $height)
# Adapta el motor y todas las escalas al tamano real del canvas. Se invoca
# desde el evento <Configure>. Mantiene la cantidad de velas visibles
# (current_visible_bars) recalculando el ancho de cada vela para llenar el
# nuevo ancho, y reparte la altura entre el panel de precios y el panel ATR
# conservando la proporcion original del ATR.
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

# _min_edge_bars($total) -> $keep
# Velas minimas que deben permanecer visibles en cada extremo de navegacion.
sub _min_edge_bars {
    my ($self, $total) = @_;
    my $keep = $self->{min_edge_bars} || 2;
    return $total if $total > 0 && $keep > $total;
    return $keep;
}

# _normalized_visible_bars() -> $visible
sub _normalized_visible_bars {
    my ($self) = @_;
    my $visible = $self->{current_visible_bars} || $self->{initial_visible_bars};
    $visible = $self->{max_visible_bars} if $visible > $self->{max_visible_bars};
    $visible = $self->{min_visible_bars} if $visible < $self->{min_visible_bars};
    return $visible;
}

# _plot_width() -> px
# Ancho util del area de velas (sin franja del eje Y).
sub _plot_width {
    my ($self) = @_;
    my $strip = $self->{price_scale}{y_axis_strip_w} || 66;
    my $w     = ($self->{width} || 0) - $strip;
    return $w > 0 ? $w : 0;
}

# _max_draw_bars() -> $n
# Tope de velas a dibujar por frame (evita miles de objetos Tk en zoom-out).
sub _max_draw_bars {
    my ($self) = @_;
    my $pw = $self->_plot_width();
    return 1200 if $pw <= 0;
    return int($pw * 2) + 4;
}

# _update_y_data_cache($start, $end, [$vatr])
# Guarda min/max de datos visibles para acotar el zoom vertical manual.
sub _update_y_data_cache {
    my ($self, $start, $end, $vatr) = @_;
    if (defined $start && defined $end && $end >= $start) {
        my @pr = $self->_auto_scale_y_range($start, $end);
        $self->{_cached_price_y} = \@pr if @pr == 2 && $pr[1] > $pr[0];
    }
    return unless $vatr && ref $vatr eq 'ARRAY' && @$vatr;

    my ($lo, $hi);
    for my $v (@$vatr) {
        next unless defined $v;
        $lo = $v if !defined $lo || $v < $lo;
        $hi = $v if !defined $hi || $v > $hi;
    }
    $self->{_cached_atr_y} = [$lo, $hi]
        if defined $lo && defined $hi && $hi >= $lo;
}

# _atr_zoom_opts() -> \%opts
sub _atr_zoom_opts {
    my ($self) = @_;
    my %opts = (panel_height => $self->{atr_height});
    if ($self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2) {
        @opts{qw(data_min data_max)} = @{$self->{_cached_atr_y}};
    }
    return \%opts;
}

# _atr_zoom_wheel($dir)
sub _atr_zoom_wheel {
    my ($self, $dir) = @_;
    return unless defined $dir;
    return unless $self->{atr_scale};
    return unless $self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2;

    my $ph  = $self->{price_height} || 0;
    my $ah  = $self->{atr_height}   || 110;
    my $y   = $self->{crosshair_y};

    # FIX-4b: si el cursor esta en la franja del eje Y del ATR, la Y puede
    # estar fuera del rango valido del panel ATR (ph..ph+ah). Acotamos al
    # centro del panel ATR para que el ancla del zoom sea estable.
    if (!defined $y || $y < $ph || $y > $ph + $ah) {
        $y = $ph + $ah / 2;
    }

    $self->{atr_auto_scale} = 0;
    Market::Core::ATRPanelZoom::apply_wheel_at_y(
        $self->{atr_scale}, $y, $dir, $self->_atr_zoom_opts(),
    );
    $self->request_render();
}

# _atr_zoom_drag($mouse_y, $dy)
sub _atr_zoom_drag {
    my ($self, $mouse_y, $dy) = @_;
    return unless defined $mouse_y && defined $dy && $dy != 0;
    return unless $self->{atr_scale};
    return unless $self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2;

    $self->{atr_auto_scale} = 0;
    Market::Core::ATRPanelZoom::apply_drag_at_y(
        $self->{atr_scale}, $mouse_y, $dy, $self->_atr_zoom_opts(),
    );
    $self->{atr_scale}->{scale_drag_active} = 1;
    $self->_request_render_throttled();
}

# _vertical_zoom_opts($target) -> \%opts
sub _vertical_zoom_opts {
    my ($self, $target) = @_;
    my %opts;
    if ($target eq 'atr') {
        $opts{panel_height}   = $self->{atr_height};
        $opts{min_span_ratio} = 0.10;
        $opts{max_span_ratio} = 4.0;
        if ($self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2) {
            @opts{qw(data_min data_max)} = @{$self->{_cached_atr_y}};
        }
    }
    else {
        $opts{panel_height} = $self->{price_height};
        if ($self->{_cached_price_y} && @{$self->{_cached_price_y}} == 2) {
            @opts{qw(data_min data_max)} = @{$self->{_cached_price_y}};
        }
        else {
            # FIX-3b: cache de precio vacia (primer zoom antes del primer render).
            # Calculamos el rango en caliente para que _bound_range tenga limites
            # y no dispare el rango de la escala a valores absurdos.
            my $s = $self->{start_idx} // 0;
            my $e = $self->{end_idx};
            if (defined $e && $e >= $s) {
                my ($mn, $mx) = $self->_auto_scale_y_range($s, $e);
                if (defined $mn && defined $mx && $mx > $mn) {
                    $opts{data_min} = $mn;
                    $opts{data_max} = $mx;
                    # Guardamos en cache para los eventos Motion subsiguientes.
                    $self->{_cached_price_y} = [$mn, $mx];
                }
            }
        }
    }
    return \%opts;
}

# _ensure_scale_covers_data($target)
# Si el rango manual dejo los datos fuera, reencaja antes de zoom.
sub _ensure_scale_covers_data {
    my ($self, $target) = @_;
    my $scale = $target eq 'atr' ? $self->{atr_scale} : $self->{price_scale};
    return unless $scale;

    my $opts = $self->_vertical_zoom_opts($target);
    return unless defined $opts->{data_min} && defined $opts->{data_max};

    my ($min, $max) = $scale->get_range();
    my $lo = $opts->{data_min};
    my $hi = $opts->{data_max};
    return if $max >= $lo && $min <= $hi;

    Market::Core::VerticalScaleZoom::fit_to_data(
        $scale, $lo, $hi,
        { padding_ratio => $target eq 'atr' ? 0.10 : 0.06 },
    );
}

# _repair_manual_scale_if_data_outside($target)
# En MANUAL no reencajar la escala en cada frame: eso anula pan y zoom vertical.
# Solo recuperar si los datos visibles quedaron totalmente fuera del rango Y.
sub _repair_manual_scale_if_data_outside {
    my ($self, $target) = @_;
    $target ||= 'price';

    if ($target eq 'atr') {
        return if $self->{atr_auto_scale};
        my $scale = $self->{atr_scale};
        return unless $scale;
        return unless $self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2;
        my ($lo, $hi) = @{$self->{_cached_atr_y}};
        my ($min, $max) = $scale->get_range();
        return unless defined $min && defined $max && $max > $min;
        return if $max >= $lo && $min <= $hi;
        Market::Core::ATRPanelZoom::fit_to_data(
            $scale, $lo, $hi, { padding_ratio => 0.10 },
        );
        return;
    }

    return if $self->{auto_scale};
    my $scale = $self->{price_scale};
    return unless $scale;
    return unless $self->{_cached_price_y} && @{$self->{_cached_price_y}} == 2;
    my ($lo, $hi) = @{$self->{_cached_price_y}};
    my ($min, $max) = $scale->get_range();
    return unless defined $min && defined $max && $max > $min;
    return if $max >= $lo && $min <= $hi;
    Market::Core::VerticalScaleZoom::fit_to_data(
        $scale, $lo, $hi, { padding_ratio => 0.06 },
    );
}

# _auto_scale_y_range($s_start, $s_end) -> ($min, $max)
# Rango Y para auto-escala con muestreo si el tramo es muy largo.
sub _auto_scale_y_range {
    my ($self, $s_start, $s_end) = @_;
    return unless $self->{market_data};
    return unless defined $s_start && defined $s_end && $s_end >= $s_start;

    my $cap = 600;
    my $n   = $s_end - $s_start + 1;
    if ($n <= $cap) {
        my $slice = $self->{market_data}->get_slice($s_start, $s_end);
        return $self->{price_panel}->get_y_range($slice) if $slice && @$slice;
        return;
    }

    my $stride = int($n / $cap) + 1;
    my ($min_p, $max_p);
    for (my $i = $s_start; $i <= $s_end; $i += $stride) {
        my $c = $self->{market_data}->get_candle($i);
        next unless $c && defined $c->{low} && defined $c->{high};
        $min_p = $c->{low}  if !defined $min_p || $c->{low}  < $min_p;
        $max_p = $c->{high} if !defined $max_p || $c->{high} > $max_p;
    }
    my $last = $self->{market_data}->get_candle($s_end);
    if ($last && defined $last->{low} && defined $last->{high}) {
        $min_p = $last->{low}  if !defined $min_p || $last->{low}  < $min_p;
        $max_p = $last->{high} if !defined $max_p || $last->{high} > $max_p;
    }
    return ($min_p, $max_p);
}

# _prepare_draw_slice($draw_start, $draw_end) -> ($slice, $first_index, $stride)
# Evita copiar/decimar en el panel cuando hay decenas de miles de velas.
sub _prepare_draw_slice {
    my ($self, $ds, $de) = @_;
    return ([], $ds, 1) unless $self->{market_data};
    return ([], $ds, 1) unless defined $ds && defined $de && $de >= $ds;

    my $max = $self->_max_draw_bars();
    my $n   = $de - $ds + 1;
    if ($n <= $max) {
        my $slice = $self->{market_data}->get_slice($ds, $de);
        return ($slice, $ds, 1);
    }

    my $stride = int($n / $max) + 1;
    my @out;
    for (my $i = $ds; $i <= $de; $i += $stride) {
        my $c = $self->{market_data}->get_candle($i);
        push @out, $c if $c;
    }
    my $last = $self->{market_data}->get_candle($de);
    if ($last && (!@out || $out[-1] != $last)) {
        push @out, $last;
    }
    return (\@out, $ds, $stride);
}

# _horizontal_offset_limits($visible, $total) -> ($min_offset, $max_offset)
# Unica fuente de verdad para los topes de scroll horizontal (offset entero).
#
# Geometria: view_start = total - visible - offset; end_visual = total-1-offset.
#   - offset = 0: vista reciente (ultima vela anclada a la derecha del viewport).
#   - offset = total - visible: vista historica (barra 0 al borde izquierdo util).
#   - offset = keep - visible: extremo futuro (keep ultimas velas + whitespace).
#
# Con visible > total el historico queda en offset negativo (total-visible); el
# tope superior del rango sigue siendo offset=0 (reciente), no el historico.
sub _horizontal_offset_limits {
    my ($self, $visible, $total) = @_;
    return (0, 0) unless $total > 0 && $visible > 0;

    my $keep       = $self->_min_edge_bars($total);
    my $min_offset = $keep - $visible;
    $min_offset = 0 if $min_offset > 0;
    my $max_offset = $total - $visible;
    $max_offset = 0 if $max_offset < 0;
    return ($min_offset, $max_offset);
}

# _offset_at_historical_extreme($visible, $total) -> $offset
sub _offset_at_historical_extreme {
    my ($self, $visible, $total) = @_;
    return 0 unless $total > 0 && $visible > 0;
    return $total - $visible;
}

# _offset_at_future_extreme($visible, $total) -> $offset
sub _offset_at_future_extreme {
    my ($self, $visible, $total) = @_;
    return 0 unless $total > 0 && $visible > 0;
    my ($min_offset) = $self->_horizontal_offset_limits($visible, $total);
    return $min_offset;
}

# _enforce_horizontal_offset($visible, $total) -> $clamped
# Acota offset a los limites. Debe invocarse tras CUALQUIER cambio de offset,
# visible_bars o candle_width (via compute_window).
sub _enforce_horizontal_offset {
    my ($self, $visible, $total) = @_;
    $self->{offset} = 0 unless defined $self->{offset};
    return 0 unless $total > 0 && $visible > 0;

    my ($min_o, $max_o) = $self->_horizontal_offset_limits($visible, $total);
    my $before = $self->{offset};
    $self->{offset} = $min_o if $self->{offset} < $min_o;
    $self->{offset} = $max_o if $self->{offset} > $max_o;
    return ($before != $self->{offset}) ? 1 : 0;
}

# _clamp_x_shift_horizontal($visible, $total, $min_offset, $max_offset)
# Acota x_shift para que en los extremos queden `keep` velas ancladas al borde
# correcto (historico = izquierda, futuro = derecha), con whitespace opuesto.
sub _clamp_x_shift_horizontal {
    my ($self, $visible, $total, $min_offset, $max_offset) = @_;
    return unless $total > 0 && $visible > 0;

    my $cw = $self->{candle_width} || 1;
    return if $cw <= 0;

    my $plot_w = $self->_plot_width();
    return if $plot_w <= 0;

    my $keep = $self->_min_edge_bars($total);
    my $off  = $self->{offset};
    my $end_visual = $total - 1 - $off;
    my $vstart     = $end_visual - $visible + 1;
    my $xs         = $self->{x_shift} || 0;

    my $hist_off = $self->_offset_at_historical_extreme($visible, $total);
    my $at_historical = ($visible > $total)
        ? ($off <= $hist_off + 1e-9)
        : ($off >= $hist_off - 1e-9);
    my $at_future = ($off <= $min_offset + 1e-9);

    if ($at_historical) {
        # Extremo historico: las `keep` velas mas antiguas pegadas a la IZQUIERDA.
        # vstart=0 (visible<=total) o vstart negativo con zoom-out (visible>total).
        my $first_slot = 0 - $vstart;          # slot donde cae la barra 0
        $first_slot = 0 if $first_slot < 0;
        my $min_xs = 0.01 - $first_slot * $cw; # barra 0 no sale por la izquierda
        my $max_xs = $plot_w - $keep * $cw - 0.01 - $first_slot * $cw;
        if ($max_xs < $min_xs) {
            $xs = $min_xs;
        }
        else {
            $xs = $min_xs if $xs < $min_xs;
            $xs = $max_xs if $xs > $max_xs;
        }
    }
    elsif ($at_future) {
        # Extremo futuro: las `keep` velas mas recientes pegadas a la DERECHA.
        # vstart = total - keep; x_shift positivo las empuja a slots derechos.
        my $canonical = ($visible - $keep) * $cw;
        my $last_slot = ($total - 1) - $vstart;
        my $min_xs = 0.01;
        my $max_xs = $plot_w - ($last_slot + 1) * $cw - 0.01;
        if ($max_xs < $min_xs) {
            $xs = $canonical;
        }
        else {
            # Preferir anclaje derecho; permitir pan fino hacia la izquierda.
            $xs = $canonical if abs($xs) < 1e-6 && $max_xs >= $canonical;
            $xs = $min_xs if $xs < $min_xs;
            $xs = $max_xs if $xs > $max_xs;
        }
    }
    else {
        # Posicion intermedia: al menos una vela del tramo de datos en pantalla.
        my $lo = $self->{start_idx};
        my $hi = $self->{end_idx};
        if (defined $lo && defined $hi && $hi >= $lo) {
            my $min_xs = -($lo - $vstart) * $cw + 0.01;
            my $max_xs = $plot_w - ($hi - $vstart) * $cw - 0.01;
            if ($min_xs <= $max_xs) {
                $xs = $min_xs if $xs < $min_xs;
                $xs = $max_xs if $xs > $max_xs;
            }
        }
    }

    $self->{x_shift} = $xs;
}

sub compute_window {
    my ($self) = @_;
    my $total = $self->{market_data}->size;
    $self->{total_bars} = $total;
    return (0, 0) unless $total > 0;

    my $visible = $self->_normalized_visible_bars();
    # NO se acota $visible a $total: zoom-out "mas alla de la data" (TradingView).

    my ($min_offset, $max_offset) = $self->_horizontal_offset_limits($visible, $total);
    $self->_enforce_horizontal_offset($visible, $total);

    # end_visual puede superar total-1: esos "slots" sobrantes son el whitespace.
    my $end_visual = $total - 1 - $self->{offset};
    my $start      = $end_visual - $visible + 1;

    $self->{view_start} = $start;

    my $data_start = $start;      $data_start = 0          if $data_start < 0;
    my $data_end   = $end_visual; $data_end   = $total - 1 if $data_end > $total - 1;
    $data_end = 0 if $data_end < 0;

    # Replay: nunca exponer velas futuras al puntero (spec 3).
    if ($self->{replay_controller} && $self->{replay_controller}->can('visible_limit')
        && $self->{replay_controller}->{enabled})
    {
        my $limit = $self->{replay_controller}->visible_limit($total);
        if (defined $limit && $data_end > $limit) {
            $data_end = $limit;
            if ($data_start > $data_end) {
                $data_start = $data_end - $visible + 1;
                $data_start = 0 if $data_start < 0;
            }
        }
    }

    $self->{visible_bars} = $data_end - $data_start + 1;
    $self->{start_idx}    = $data_start;
    $self->{end_idx}      = $data_end;

    $self->_clamp_x_shift_horizontal($visible, $total, $min_offset, $max_offset);
    $self->_sync_infra_state();

    return ($data_start, $data_end);
}

# ── Render ────────────────────────────────────────────────────────────────────

sub request_render {
    my ($self) = @_;
    return unless $self->{canvas};
    return if $self->{pending};
    $self->{pending} = 1;
    $self->{canvas}->afterIdle(sub {
        $self->{pending} = 0;
        $self->render();
    });
}

# _request_render_throttled()
# Igual que request_render pero con tope de ~60fps (coalescing temporal). Para
# gestos continuos (pan con arrastre, drag de la escala Y, zoom con rueda) que de
# otro modo dispararian un render() SINCRONO por cada pixel/notch de movimiento,
# saturando el event loop monohilo de Tk. El estado del viewport ya se actualizo
# antes de llamar a esto, asi que el render coalescido usa siempre el ultimo.
sub _request_render_throttled {
    my ($self) = @_;
    return unless $self->{canvas};
    return if $self->{pending};
    $self->{pending} = 1;
    $self->{canvas}->after(16, sub {
        $self->{pending} = 0;
        $self->render();
    });
}

sub render {
    my ($self) = @_;
    return unless $self->{canvas} && $self->{market_data};

    my ($start, $end) = $self->compute_window();
    return if $end < $start;
    my $total = $self->{total_bars} || $self->{market_data}->size;
    if ($self->{replay_controller} && $self->{replay_controller}->can('visible_limit') && $self->{replay_controller}->{enabled}) {
        my $limit = $self->{replay_controller}->visible_limit($total);
        $end = $limit if defined $limit && $end > $limit;
        $end = $start if $end < $start;
    }

    # Relleno de 1 vela a cada lado: con el desplazamiento sub-pixel (x_shift) la
    # vela del borde podria dejar un hueco de hasta media vela. Dibujar una vela
    # extra a cada lado cubre ese hueco (las sobrantes caen fuera del area util).
    my $draw_start = $start - 1; $draw_start = 0          if $draw_start < 0;
    my $draw_end   = $end   + 1; $draw_end   = $total - 1 if $draw_end > $total - 1;
    if ($self->{replay_controller} && $self->{replay_controller}->{enabled}) {
        my $limit = $self->{replay_controller}->visible_limit($total);
        $draw_end = $limit if defined $limit && $draw_end > $limit;
    }

    my ($data_slice, $slice_first, $draw_stride) =
        $self->_prepare_draw_slice($draw_start, $draw_end);
    return unless $data_slice && ref $data_slice eq 'ARRAY' && @$data_slice;

    # Auto-escala Y (cuando auto_scale esta activo): se calcula sobre una ventana
    # ESTABLE de las ultimas `eff` velas (las que caben en el viewport segun el
    # zoom), terminando en la ultima vela real visible. NO se usa solo el tramo
    # real visible: al desplazarse hacia el futuro (whitespace) quedarian pocas
    # velas y el rango colapsaria, agrandando las velas de forma exagerada.
    #   - Scroll normal / historico: la ventana coincide con las velas visibles
    #     => el rango se ajusta exactamente a lo que se ve (como TradingView).
    #   - Scroll hacia el futuro (whitespace): la ventana se mantiene en las
    #     ultimas `eff` velas => la escala queda estable y las velas no crecen.
    if ($self->{auto_scale} && !$self->{_skip_auto_scale} && !$self->{_auto_y_frozen}) {
        my $eff = $self->{current_visible_bars} || $self->{initial_visible_bars};
        $eff = $total      if defined $total && $eff > $total;
        my $s_end   = $end;
        my $s_start = $s_end - $eff + 1;
        $s_start = 0 if $s_start < 0;

        my ($min_p, $max_p) = $self->_auto_scale_y_range($s_start, $s_end);
        if (defined $min_p && defined $max_p && $max_p > $min_p) {
            my $pad = ($max_p - $min_p) * 0.04;
            $pad = 1 unless $pad > 0;
            $self->{price_scale}->set_range($min_p - $pad, $max_p + $pad);
        }
    }

    # start_index LOGICO (no el de relleno) + x_shift sub-pixel comun a las dos
    # escalas, para que velas, ATR, eje de tiempo y crosshair queden alineados.
    my $xshift = $self->{x_shift} || 0;
    # start_index = view_start (indice logico del borde izquierdo, puede ser
    # negativo si hay whitespace a la izquierda). Asi las velas se anclan al borde
    # derecho cuando se comprime toda la data, sin pegarse a la izquierda.
    my $vstart = defined $self->{view_start} ? $self->{view_start} : $start;
    my $max_draw = $self->_max_draw_bars();
    $self->{price_scale}->{start_index}  = $vstart;
    $self->{atr_scale}->{start_index}    = $vstart;
    $self->{price_scale}->{x_shift}      = $xshift;
    $self->{atr_scale}->{x_shift}        = $xshift;
    $self->{price_scale}->{max_draw_bars} = $max_draw;
    $self->{price_scale}->{draw_stride}    = $draw_stride;
    $self->{price_scale}->{draw_end_index} = $draw_end;
    $self->{atr_scale}->{max_draw_bars}     = $max_draw;
    $self->{atr_scale}->{draw_stride}       = $draw_stride;
    $self->{atr_scale}->{draw_end_index}    = $draw_end;

    my $tick_labels = $self->compute_intraday_labels($start, $end);

    $self->_update_y_data_cache($start, $end);
    # FIX-1: en MANUAL no reencajar la escala en cada frame (anula pan/zoom).
    # Solo recuperar si los datos visibles quedaron totalmente fuera del rango.
    $self->_repair_manual_scale_if_data_outside('price');

    $self->{price_panel}->render($self->{canvas}, $data_slice, $self->{price_scale}, $slice_first);
    $self->{price_scale}->_draw_y_scale($self->{canvas});
    # Caja/linea del ultimo precio por ENCIMA de la mascara del eje Y.
    $self->{canvas}->raise('visible_background');
    $self->{canvas}->raise('visible_price');

    # Overlays SOLO en el panel de precios (antes del ATR, estilo TradingView).
    $self->_prepare_overlay_data();
    $self->_draw_overlays();
    $self->_clip_overlays_to_price_panel();

    # Fondos y separadores de paneles (tapa cualquier desborde residual).
    $self->_draw_pane_layout();

    my $atr_ind = $self->{indicator_manager}
        ? $self->{indicator_manager}->get('atr')
        : undef;

    if ($atr_ind) {
        my $values = $atr_ind->get_values || [];
        if (@$values) {
            my $period = $atr_ind->{period} || 14;
            my $aoff   = $period - 1;
            # Mismo rango de relleno que las velas (draw_start..draw_end).
            my $vs = $draw_start - $aoff;  $vs = 0         if $vs < 0;
            my $ve = $draw_end   - $aoff;  $ve = $#$values if $ve > $#$values;
            if ($vs <= $ve) {
                my @vatr;
                my $atr_stride = 1;
                my $atr_n = $ve - $vs + 1;
                if ($atr_n > $max_draw) {
                    $atr_stride = int($atr_n / $max_draw) + 1;
                    for (my $j = $vs; $j <= $ve; $j += $atr_stride) {
                        push @vatr, $values->[$j];
                    }
                    push @vatr, $values->[$ve]
                        if $ve >= $vs && (!@vatr || $vatr[-1] != $values->[$ve]);
                }
                else {
                    @vatr = @{$values}[$vs .. $ve];
                }
                my $atr_first = $vs + $aoff;
                $self->_update_y_data_cache($start, $end, \@vatr);
                if ($self->{atr_auto_scale} && $self->{_cached_atr_y}
                    && @{$self->{_cached_atr_y}} == 2)
                {
                    Market::Core::ATRPanelZoom::fit_to_data(
                        $self->{atr_scale}, @{$self->{_cached_atr_y}},
                    );
                }
                elsif (!$self->{atr_auto_scale}) {
                    $self->_repair_manual_scale_if_data_outside('atr');
                }
                $self->{atr_scale}->{draw_stride} = $atr_stride;
                $self->{atr_panel}->render($self->{canvas}, \@vatr, $self->{atr_scale}, $atr_first);
                $self->{atr_scale}->_draw_y_scale($self->{canvas});
                $self->{canvas}->raise('atr_line');
                $self->{canvas}->raise('atr_y_scale');
                $self->{canvas}->raise('atr_background');
                $self->{canvas}->raise('atr_last_value');
                $self->{canvas}->raise('panel_separator');
            }
        }
    }

    # Eje de tiempo al fondo (debajo del panel ATR).
    $self->{price_panel}->draw_time_axis(
        $self->{canvas}, $tick_labels, $self->{price_scale},
        $self->_time_axis_y, $self->{time_axis_height});
    $self->{canvas}->raise('time_labels');

    $self->_draw_replay_marker();
    # Durante zoom: solo crosshair (alineado al nuevo mapeo X); HUD diferido.
    $self->_draw_crosshair_all();
    $self->_draw_hud() unless $self->{_zoom_frame};
}

sub _draw_overlays {
    my ($self) = @_;
    return unless $self->{canvas};
    return unless $self->{overlay_manager};

    # Limpiar TODAS las capas registradas aunque esten desactivadas.
    # Si solo se dibujaran las activas, al desmarcar un checkbox los elementos
    # previos quedarian pegados al canvas (draw() ya no se invoca -> sin clear).
    if ($self->{overlay_manager}->can('list')) {
        for my $name (@{ $self->{overlay_manager}->list() || [] }) {
            my $overlay = $self->{overlay_manager}->get($name);
            $overlay->clear($self->{canvas}) if $overlay && $overlay->can('clear');
        }
    }

    my $overlays = $self->{overlay_manager}->can('active_overlays')
        ? $self->{overlay_manager}->active_overlays()
        : [];
    return unless $overlays && ref($overlays) eq 'ARRAY';

    for my $overlay (@$overlays) {
        next unless $overlay;
        next unless $overlay->can('draw');
        $overlay->draw(
            canvas      => $self->{canvas},
            scale       => $self->{price_scale},
            atr_scale   => $self->{atr_scale},
            market_data => $self->{market_data},
            start_idx   => $self->{start_idx},
            end_idx     => $self->{end_idx},
            view_start  => $self->{view_start},
            x_shift     => $self->{x_shift},
            clip_y_top    => 0,
            clip_y_bottom => $self->{price_height},
            data        => $overlay->{data},
        );
    }

    # Asegurar que overlays queden encima de velas/fondos del panel de precios.
    for my $tag (qw(overlay_liquidity overlay_fvg overlay_structure)) {
        eval { $self->{canvas}->raise($tag); };
    }

    return $self;
}

# _draw_pane_layout()
# Separa visualmente precio | ATR | eje de tiempo (estilo TradingView).
sub _draw_pane_layout {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;

    my $w   = $self->{width}  || 1000;
    my $ph  = $self->{price_height} || 0;
    my $ah  = $self->{atr_height}   || 140;
    my $tah = $self->{time_axis_height} || 42;
    my $ty  = $ph + $ah;

    $canvas->delete('pane_layout');

    # Fondo del panel ATR (cubre desbordes de overlays/velas).
    $canvas->createRectangle(
        0, $ph, $w, $ty,
        -fill => '#0f1720', -outline => '',
        -tags => ['pane_layout', 'atr_pane_bg'],
    );

    # Fondo del eje de tiempo.
    $canvas->createRectangle(
        0, $ty, $w, $ty + $tah,
        -fill => '#131722', -outline => '',
        -tags => ['pane_layout', 'time_axis_bg'],
    );

    # Separador precio / ATR.
    $canvas->createLine(
        0, $ph, $w, $ph,
        -fill => '#363a45', -width => 2,
        -tags => ['pane_layout', 'panel_separator'],
    );

    return $self;
}

# _clip_overlays_to_price_panel()
# Oculta elementos de overlay que queden por debajo del panel de precios.
sub _clip_overlays_to_price_panel {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    my $ph     = $self->{price_height} || 0;
    return unless $canvas && $ph > 0;

    my @tags = qw(overlay_liquidity overlay_fvg overlay_structure);

    for my $tag (@tags) {
        for my $id ($canvas->find('withtag', $tag)) {
            my @bbox = $canvas->bbox($id);
            next unless @bbox >= 4;
            if ($bbox[1] >= $ph - 1) {
                $canvas->itemconfigure($id, -state => 'hidden');
            }
        }
    }
    return $self;
}

# _in_atr_panel($y) -> bool
sub _in_atr_panel {
    my ($self, $y) = @_;
    return 0 unless defined $y;
    my $ph = $self->{price_height} || 0;
    my $ah = $self->{atr_height}   || 0;
    return ($y >= $ph && $y <= $ph + $ah) ? 1 : 0;
}

# _draw_replay_marker()
# Linea vertical en la vela del puntero de replay (referencia visual).
sub _draw_replay_marker {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    $canvas->delete('replay_marker');

    my $rc = $self->{replay_controller};
    return unless $rc && $rc->is_active();

    my $idx = $rc->{current_index};
    return unless defined $idx;

    my $x = $self->{price_scale}->index_to_center_x($idx);
    my $y0 = 0;
    my $y1 = ($self->{price_height} || 0) + ($self->{atr_height} || 0);

    $canvas->createLine($x, $y0, $x, $y1,
        -fill => '#66bb6a', -width => 1, -dash => [6, 4],
        -tags => ['replay_marker'],
    );
    $canvas->raise('replay_marker');
    return $self;
}

# _time_axis_y() -> $y
# Coordenada Y donde vive el eje de tiempo comun: justo debajo del panel ATR,
# al fondo del grafico. Las etiquetas del eje y la fecha del crosshair se anclan
# a esta linea, garantizando sincronia entre todos los paneles.
sub _time_axis_y {
    my ($self) = @_;
    return $self->{price_height} + $self->{atr_height};
}

# Registra solo overlays de la primera entrega (29/06): Liquidez, SMC, FVG.
sub _register_overlays {
    my ($self) = @_;
    return unless $self->{overlay_manager} && $self->{overlay_manager}->can('register');

    my @overlays = (
        [liquidity => $self->{liquidity_overlay}],
        [fvg       => $self->{fvg_overlay}],
        [structure => $self->{structure_overlay}],
    );

    for my $entry (@overlays) {
        my ($name, $overlay) = @$entry;
        next unless $overlay;
        $self->{overlay_manager}->register($name, $overlay);
        $self->{overlay_manager}->enable($name) if $self->{overlay_manager}->can('enable');
    }
    $self->_sync_overlay_layer_state();
    return $self;
}

# ── Cache de analisis (desacople ANALISIS / RENDER) ───────────────────────────
#
# Los motores de Liquidity, Structure y FVG analizan el dataset completo;
# su resultado solo cambia cuando cambian los DATOS (ver entregable 29/06).

# invalidate_analysis_cache()
sub invalidate_analysis_cache {
    my ($self) = @_;
    $self->{analysis_cache} = undef;
    for my $key (qw(liquidity_engine structure_engine fvg_engine)) {
        my $eng = $self->{$key};
        $eng->reset() if $eng && $eng->can('reset');
    }
    return $self;
}

# rebuild_analysis_cache() — primera entrega 29/06: Liquidity, Structure, FVG.
sub rebuild_analysis_cache {
    my ($self) = @_;
    return unless $self->{market_data};

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

    my %engine_args = (
        replay_controller => $self->{replay_controller},
        timeframe         => $timeframe,
        view_start        => $view_start,
        view_end          => $view_end,
    );

    for my $key (qw(liquidity_engine structure_engine fvg_engine)) {
        my $eng = $self->{$key};
        $eng->reset() if $eng && $eng->can('reset');
    }

    if ($self->{liquidity_engine} && $self->{liquidity_engine}->can('visible_only')) {
        $self->{liquidity_engine}->visible_only(1);
    }
    my $liquidity_data = $self->{liquidity_engine}->calculate($self->{market_data}, %engine_args);
    my $structure_data = $self->{structure_engine}->calculate(
        $self->{market_data}, %engine_args, liquidity_result => $liquidity_data,
    );
    if ($self->{liquidity_engine} && $self->{liquidity_engine}->can('apply_structure_filter')) {
        $liquidity_data = $self->{liquidity_engine}->apply_structure_filter(
            $structure_data,
            $self->{market_data},
            %engine_args,
        ) || $liquidity_data;
    }
    $self->_enrich_liquidity_with_structure_scope($liquidity_data, $structure_data);
    my $fvg_data = $self->{fvg_engine}->calculate(
        $self->{market_data}, $self->{structure_engine}, %engine_args,
    );

    $self->{analysis_cache} = {
        liquidity => $liquidity_data,
        structure => $structure_data,
        fvg       => $fvg_data,
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

    my $overlay_names = {
        liquidity => $liquidity_data,
        structure => $structure_data,
        fvg       => $fvg_data,
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
sub _in_price_panel {
    my ($self, $y) = @_;
    return 0 unless defined $y;
    my $ph = $self->{price_height} || 0;
    return ($y >= 0 && $y <= $ph) ? 1 : 0;
}

# _in_price_y_axis_strip($x, $y) -> bool
# Verdadero si el cursor esta sobre la franja del eje Y de precios (derecha).
sub _in_price_y_axis_strip {
    my ($self, $x, $y) = @_;
    return Market::Core::YAxisHitTest::in_y_axis_strip(
        $x, $y,
        width     => $self->{width} || 0,
        strip_w   => $self->{price_scale}{y_axis_strip_w} || 66,
        y_top     => 0,
        y_bottom  => $self->{price_height} || 0,
    );
}

# _in_atr_y_axis_strip($x, $y) -> bool
sub _in_atr_y_axis_strip {
    my ($self, $x, $y) = @_;
    my $ph = $self->{price_height} || 0;
    return Market::Core::YAxisHitTest::in_y_axis_strip(
        $x, $y,
        width     => $self->{width} || 0,
        strip_w   => $self->{atr_scale}{y_axis_strip_w} || 66,
        y_top     => $ph,
        y_bottom  => $ph + ($self->{atr_height} || 0),
    );
}

# _hide_crosshair_all()
# Oculta todo el crosshair (estilo TradingView al entrar en la escala de precios).
sub _hide_crosshair_all {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    $self->{price_panel}->hide_crosshair($canvas) if $self->{price_panel};
    $canvas->delete('atr_crosshair');
}

# _draw_crosshair_all()
# Dibuja el crosshair en todos los paneles con SNAP a la vela bajo el cursor:
# la linea vertical, la fecha y el OHLC usan el centro de esa vela y quedan
# perfectamente alineados. En la zona de whitespace (a la derecha de la ultima
# vela) la linea sigue libremente al cursor y la fecha se oculta.
# ESCALAY: sobre la franja del eje Y de precios no se muestra crosshair ni OHLC.
sub _draw_crosshair_all {
    my ($self) = @_;
    return unless defined $self->{crosshair_x};
    my $canvas = $self->{canvas};
    my $x = $self->{crosshair_x};
    my $y = $self->{crosshair_y} || 0;

    if ($self->_in_price_y_axis_strip($x, $y) || $self->_in_atr_y_axis_strip($x, $y)) {
        $self->{crosshair_idx} = undef;
        $self->_hide_crosshair_all();
        return;
    }

    my $atr_bottom = $self->{price_height} + $self->{atr_height};

    my $line_x   = $x;
    my $snap_idx;
    if (defined $self->{start_idx} && defined $self->{end_idx}) {
        my $raw = $self->{price_scale}->x_to_index($x);
        if ($raw >= $self->{start_idx} && $raw <= $self->{end_idx}) {
            $snap_idx = $raw;
            $line_x   = $self->{price_scale}->index_to_center_x($raw);
        }
    }
    $self->{crosshair_idx} = $snap_idx;   # fuente unica de verdad para el HUD

    $self->{price_panel}->draw_crosshair($canvas, $line_x, $y, 0, $self->{price_height});
    $self->{atr_panel}->draw_crosshair($canvas, $line_x, $y, $self->{price_height}, $atr_bottom);
    $self->_draw_crosshair_time_label($snap_idx, $line_x);
}

# _draw_crosshair_time_label($idx, $cx)
# Dibuja la etiqueta de fecha/hora de la vela $idx centrada en $cx, sobre el eje
# de tiempo del fondo. Si $idx no esta definido (whitespace / fuera de datos),
# oculta la etiqueta. Usa el mismo indice que el snap del crosshair y el HUD.
sub _draw_crosshair_time_label {
    my ($self, $idx, $cx) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas && defined $cx;

    my $baseline = $self->_time_axis_y;
    my $ts = defined $idx ? $self->{market_data}->get_timestamp($idx) : undef;
    unless (defined $ts) {
        $self->{price_panel}->draw_time_label($canvas, $cx, undef, $baseline);
        return;
    }

    my $text = $self->_format_crosshair_time($ts);
    $self->{price_panel}->draw_time_label($canvas, $cx, $text, $baseline);
}

# _format_crosshair_time($epoch) -> $string
# Da formato legible al timestamp. Las temporalidades soportadas (1m/5m/15m)
# son intradia, por lo que se muestra fecha y hora: DD/MM/YYYY HH:MM.
# Si la vela cae exactamente a medianoche (00:00), se muestra solo la fecha
# (DD/MM/YYYY), "segun corresponda".
# _tz_offset() -> $seconds
# Offset de la zona del mercado (del dataset). Se usa con gmtime($ts + offset)
# para obtener la hora local del mercado SIN depender de la zona de la maquina.
sub _tz_offset {
    my ($self) = @_;
    return 0 unless $self->{market_data} && $self->{market_data}->can('get_tz_offset');
    return $self->{market_data}->get_tz_offset;
}

sub _format_crosshair_time {
    my ($self, $ts) = @_;
    return '' unless defined $ts;

    # gmtime(epoch + offset_mercado) = hora de reloj del mercado, independiente
    # de la zona horaria de la maquina local.
    my $local_ts = $ts + $self->_tz_offset;
    my ($min, $hour, $mday, $mon, $year) = (gmtime($local_ts))[1, 2, 3, 4, 5];
    my $date = sprintf('%02d/%02d/%04d', $mday, $mon + 1, $year + 1900);

    return $date if $hour == 0 && $min == 0;
    return sprintf('%s %02d:%02d', $date, $hour, $min);
}

sub _draw_hud {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;

    $canvas->delete('hud');
    my $tf        = $self->{active_tf} || '1m';
    my $scale_lbl = $self->{auto_scale} ? 'AUTO' : 'MANUAL';
    my $visible   = $self->{current_visible_bars} || $self->{initial_visible_bars} || 0;

    # OHLC de la vela bajo el cursor. Usa el MISMO indice que el snap del
    # crosshair y la fecha (crosshair_idx), garantizando que fecha, OHLC y la
    # linea vertical correspondan exactamente a la misma vela.
    my $ohlc_line = '';
    my $idx = $self->{crosshair_idx};
    if (defined $idx) {
        my $candle = $self->{market_data}->get_candle($idx);
        if ($candle) {
            $ohlc_line = sprintf('O:%.2f H:%.2f L:%.2f C:%.2f',
                $candle->{open}, $candle->{high},
                $candle->{low},  $candle->{close});
        }
    }

    my $hud_h = $ohlc_line ? 90 : 72;
    my $replay_line = '';
    if ($self->{replay_controller} && $self->{replay_controller}->is_active()) {
        my $rc = $self->{replay_controller};
        my $pos = ($rc->{current_index} // 0) + 1;
        my $tot = $self->{market_data} ? $self->{market_data}->size() : 0;
        my $st  = $rc->{playing} ? 'PLAY' : 'PAUSE';
        $replay_line = sprintf('REPLAY %s  %d/%d', $st, $pos, $tot);
        $hud_h += 16;
    }

    $canvas->createRectangle(4, 4, 340, $hud_h,
        -fill => '#0d1117', -outline => '#2a2e39', -width => 1, -tags => ['hud']);
    $canvas->createText(12, 16,
        -text => $tf, -fill => '#e0e3ea',
        -anchor => 'w', -font => 'Helvetica 11 bold', -tags => ['hud']);
    my $sc = $self->{auto_scale} ? '#4dd0e1' : '#ff9800';
    $canvas->createText(60, 16,
        -text => "Escala: $scale_lbl", -fill => $sc,
        -anchor => 'w', -font => 'Helvetica 8', -tags => ['hud']);
    $canvas->createText(12, 33,
        -text => "Velas: $visible", -fill => '#787b86',
        -anchor => 'w', -font => 'Helvetica 8', -tags => ['hud']);
    $canvas->createText(12, 48,
        -text => '1-8: TF   r: Reset   a: Escala   p: Replay   Space: Play/Pause   [ ]: Step',
        -fill => '#4a4f5e', -anchor => 'w', -font => 'Helvetica 7', -tags => ['hud']);
    $canvas->createText(12, 61,
        -text => 'Rueda: Zoom H   Ctrl+Rueda: Zoom cursor   Shift+]: FF   Esc: Salir replay',
        -fill => '#4a4f5e', -anchor => 'w', -font => 'Helvetica 7', -tags => ['hud']);

    my $y_extra = 0;
    if ($replay_line) {
        $canvas->createText(12, 74,
            -text => $replay_line, -fill => '#66bb6a',
            -anchor => 'w', -font => 'Helvetica 8 bold', -tags => ['hud']);
        $y_extra = 16;
    }

    if ($ohlc_line) {
        $canvas->createText(12, 74 + $y_extra,
            -text   => $ohlc_line,
            -fill   => '#c0c4cc',
            -anchor => 'w',
            -font   => 'Helvetica 7',
            -tags   => ['hud']);
    }
}

# ── Eje de tiempo ─────────────────────────────────────────────────────────────

sub compute_intraday_labels {
    my ($self, $start, $end) = @_;
    return [] unless $self->{market_data};
    return [] unless defined $start && defined $end && $end >= $start;

    my $start_idx = $start;
    my $count     = $end - $start + 1;
    my $cw        = $self->{candle_width} || 4;
    my $step      = int(80 / $cw);
    $step = 1 if $step < 1;
    # Con muchas velas visibles, espaciar el escaneo de timestamps (solo etiquetas).
    if ($count > 2000) {
        my $scan = int($count / 400) + 1;
        $step = $step > $scan ? $step : $scan;
    }

    my %pos;
    for (my $i = 0; $i < $count; $i += $step) { $pos{$i} = 1; }

    my $tz      = $self->_tz_offset;
    my $prev_dk;
    my $day_step = $step;
    if ($count > 2000) {
        $day_step = int($count / 800) + 1;
        $day_step = $step if $day_step < $step;
    }
    for (my $i = 0; $i < $count; $i += $day_step) {
        my $ts = $self->{market_data}->get_timestamp($start_idx + $i);
        next unless defined $ts;
        my ($mday, $mon) = (gmtime($ts + $tz))[3, 4];
        my $dk = $mday * 100 + $mon;
        if (!defined $prev_dk || $dk != $prev_dk) {
            $pos{$i} = 1;
        }
        $prev_dk = $dk;
    }

    my $total     = $self->{total_bars} || 0;
    my $last_hist = $total > 0 ? $total - 1 : undef;
    if (defined $last_hist && $last_hist >= $start_idx && $last_hist <= $end) {
        $pos{ $last_hist - $start_idx } = 1;
    }

    my @labels;
    $prev_dk = undef;
    for my $i (sort { $a <=> $b } keys %pos) {
        my $ts = $self->{market_data}->get_timestamp($start_idx + $i);
        next unless defined $ts;
        my ($min, $hour, $mday, $mon) = (gmtime($ts + $tz))[1, 2, 3, 4];
        my $dk   = $mday * 100 + $mon;
        my $text = (!defined $prev_dk || $dk != $prev_dk)
            ? sprintf('%02d/%02d', $mday, $mon + 1)
            : sprintf('%02d:%02d', $hour, $min);
        $prev_dk = $dk;
        push @labels, { index => $start_idx + $i, text => $text };
    }
    return \@labels;
}

# ── Estabilidad visual ────────────────────────────────────────────────────────

# _keep_candles_visible()
# Intencionalmente inactivo: en MANUAL la escala Y queda fija hasta que el usuario
# la modifique en la franja del eje Y (o vuelva a AUTO con la tecla A).
sub _keep_candles_visible {
    my ($self) = @_;
    return;
}

# ── Zoom y desplazamiento ─────────────────────────────────────────────────────

# _next_visible_bars($current, $dir) -> $next
# Calcula el nuevo recuento de velas visibles para un paso de zoom, con paso
# minimo de +-1 vela (evita no-op por redondeo) y acotado a [min, max, total].
sub _next_visible_bars {
    my ($self, $current, $dir) = @_;
    my $total  = $self->{market_data}->size;
    # Paso del 20% por giro de rueda: recorre todo el rango (incluida la
    # compresion de TODA la data) en pocos giros, sin sentirse "pesado".
    my $factor = $dir < 0 ? 0.83 : 1.20;
    my $next   = int($current * $factor);
    if ($dir < 0) { $next = $current - 1 if $next >= $current; }  # zoom-in
    else          { $next = $current + 1 if $next <= $current; }  # zoom-out
    $next = $self->{min_visible_bars} if $next < $self->{min_visible_bars};
    $next = $self->{max_visible_bars} if $next > $self->{max_visible_bars};

    my $cap = $self->_zoom_out_cap($total);
    $next = $cap if $next > $cap;
    return $next;
}

# _last_visible_candle_index() -> $index | undef
# Ultima vela de DATOS cuyo cuerpo intersecta el area util del grafico (antes de la
# franja Y). NO total-1 global, NO el borde derecho del canvas, NO slots vacios
# (whitespace futuro a la derecha de la ultima vela pintada).
sub _last_visible_candle_index {
    my ($self) = @_;
    $self->compute_window();

    my $total = $self->{total_bars} || 0;
    return undef unless $total > 0;

    my $start = $self->{start_idx};
    my $end   = $self->{end_idx};
    return undef unless defined $end;

    my $strip  = $self->{price_scale}{y_axis_strip_w} || 66;
    my $plot_w = ($self->{width} || 0) - $strip;
    my $vstart = defined $self->{view_start} ? $self->{view_start} : 0;
    my $cw     = $self->{candle_width} || 1;
    my $xs     = $self->{x_shift} || 0;

    return $end if $plot_w <= 0 || $cw <= 0;

    my $lo = defined $start ? $start : 0;
    for (my $i = $end; $i >= $lo; $i--) {
        my $x_left  = (($i - $vstart) * $cw) + $xs;
        my $x_right = (($i + 1 - $vstart) * $cw) + $xs;
        return $i if $x_right > 0 && $x_left < $plot_w;
    }
    return $lo;
}

# _x_right_edge_of_index($index) -> $x
# Borde DERECHO del slot de la vela $index (misma formula que Scales/index_to_x + cw).
sub _x_right_edge_of_index {
    my ($self, $index) = @_;
    return 0 unless defined $index;
    my $vstart = defined $self->{view_start} ? $self->{view_start} : 0;
    my $xshift = $self->{x_shift} || 0;
    my $cw     = $self->{candle_width} || 1;
    return (($index + 1 - $vstart) * $cw) + $xshift;
}

# _set_anchor_x_shift($anchor_idx, $anchor_x, $cw, $right_edge)
# Calcula x_shift para mantener el ancla en anchor_x y lo acota a los limites
# horizontales. Nunca resetea a 0: si el offset se reclampa, compensa en x_shift.
sub _set_anchor_x_shift {
    my ($self, $anchor_idx, $anchor_x, $cw, $right_edge) = @_;
    return unless defined $anchor_idx && defined $anchor_x && $cw && $cw > 0;

    my $vstart = defined $self->{view_start} ? $self->{view_start} : 0;
    my $term   = $right_edge ? ($anchor_idx + 1 - $vstart) : ($anchor_idx - $vstart);
    $self->{x_shift} = $anchor_x - ($term * $cw);

    my $visible = $self->_normalized_visible_bars();
    my $total   = $self->{total_bars} || ($self->{market_data} ? $self->{market_data}->size : 0);
    return unless $total > 0 && $visible > 0;

    my ($min_o, $max_o) = $self->_horizontal_offset_limits($visible, $total);
    $self->_clamp_x_shift_horizontal($visible, $total, $min_o, $max_o);
}

# _zoom_render()
# Render del grafico durante zoom con tope de ~60fps (coalescing): una rueda
# rapida genera muchos notches; cada uno ya actualizo el estado del viewport, por
# lo que basta UN render por frame con el ultimo estado. Difiere el HUD para
# evitar parpadeos. El flag _zoom_frame omite el HUD dentro de render().
sub _zoom_render {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    return if $self->{pending};
    $self->{pending} = 1;
    $canvas->after(16, sub {
        $self->{pending}     = 0;
        $self->{_zoom_frame} = 1;
        $self->render();
        delete $self->{_zoom_frame};

        $canvas->afterCancel($self->{_zoom_hud_after}) if $self->{_zoom_hud_after};
        $self->{_zoom_hud_after} = $canvas->after(40, sub {
            delete $self->{_zoom_hud_after};
            $self->_draw_hud();
        });
    });
}

# _zoom_keep_right_edge($next, $anchor_idx, $anchor_x)
# Rueda: ancla = ultima vela visible (p. ej. 500 en 300..500). Conserva
# end_visual (offset derivado) y whitespace; solo cambia visible_bars,
# candle_width y x_shift sub-pixel.
sub _zoom_keep_right_edge {
    my ($self, $next, $anchor_idx, $anchor_x) = @_;
    return unless $next && $next > 0;
    return unless defined $anchor_idx && defined $anchor_x;

    my $total = $self->{market_data}->size;
    return unless $total > 0;

    my $offset_before = $self->{offset} || 0;
    my $end_visual    = $total - 1 - $offset_before;

    $self->{current_visible_bars} = $next;
    my $pw = $self->_plot_width();
    my $cw_new = ($pw > 0 ? $pw : $self->{width}) / $next;
    $cw_new = 1 if $cw_new <= 0;
    $self->_apply_candle_width($cw_new);

    # Mantener end_visual estable; reclampar offset solo si los limites lo exigen.
    my ($min_o, $max_o) = $self->_horizontal_offset_limits($next, $total);
    my $off = $total - 1 - $end_visual;
    $off = $min_o if $off < $min_o;
    $off = $max_o if $off > $max_o;
    $self->{offset} = $off;

    $self->compute_window();
    $self->_set_anchor_x_shift($anchor_idx, $anchor_x, $cw_new, 1);
    $self->_zoom_render();
}

# _zoom_keep_anchor($next, $idx_anchor, $anchor_x)
# Aplica el nuevo recuento de velas ($next) manteniendo el indice CONTINUO
# $idx_anchor fijo en la coordenada de pantalla $anchor_x.
#
# Precision tipo TradingView: el offset se mantiene entero (la ventana de datos
# avanza por velas), pero el residuo sub-pixel se absorbe en x_shift, calculado
# de forma EXACTA tras acotar la ventana. Asi el ancla no se mueve ni acumula
# desfase entre zooms sucesivos. Solo toca el eje X (no la escala Y), por lo que
# se comporta igual en modo automatico y manual.
sub _zoom_keep_anchor {
    my ($self, $next, $idx_anchor, $anchor_x) = @_;
    my $total = $self->{market_data}->size;
    return unless $total > 0 && $next && $next > 0;

    $self->{current_visible_bars} = $next;
    my $pw = $self->_plot_width();
    my $cw_new = ($pw > 0 ? $pw : $self->{width}) / $next;
    $cw_new = 1 if $cw_new <= 0;
    $self->_apply_candle_width($cw_new);

    # view_start objetivo (indice logico del borde izquierdo) que deja el ancla lo
    # mas cerca posible de anchor_x; de ahi el offset entero correspondiente.
    my $start_float   = $idx_anchor - ($anchor_x / $cw_new);
    my $start_tgt     = $self->round($start_float);
    my $offset_target = $total - $next - $start_tgt;
    $self->{offset}   = $offset_target;

    # compute_window acota offset/visible a los limites validos -> view_start real.
    $self->compute_window();
    $self->_set_anchor_x_shift($idx_anchor, $anchor_x, $cw_new, 0);
    $self->_zoom_render();
}

# _horizontal_zoom($dir)  ->  rueda del mouse
# $dir < 0 = zoom-in   $dir > 0 = zoom-out
#
# ANCLAJE: ultima vela visible en el viewport (p. ej. 500 en 300..500 o con
# whitespace a su derecha). Zoom hacia la izquierda; borde derecho de esa vela
# fijo en pixeles (x_shift sub-pixel, sin deriva acumulativa).
sub _horizontal_zoom {
    my ($self, $dir) = @_;
    return unless defined $dir;

    my $current = $self->{current_visible_bars} || $self->{initial_visible_bars};
    return unless $self->{market_data} && $self->{market_data}->size > 0;

    my $next = $self->_next_visible_bars($current, $dir);
    return if $next == $current;   # no-op solo en los limites reales

    my $anchor_idx = $self->_last_visible_candle_index();
    return unless defined $anchor_idx;

    my $anchor_x = $self->_x_right_edge_of_index($anchor_idx);
    $self->_zoom_keep_right_edge($next, $anchor_idx, $anchor_x);
}

# _horizontal_zoom_cursor($dir)  ->  CTRL + rueda del mouse
# $dir < 0 = zoom-in   $dir > 0 = zoom-out
#
# ANCLAJE A LA X DEL CURSOR (rueda libre estilo TradingView): el indice/timestamp
# alineado con la columna vertical del cursor permanece EXACTAMENTE en la misma X
# durante el zoom. La Y del cursor NO influye y el cursor no necesita estar sobre
# una vela concreta (se ancla la posicion horizontal continua).
sub _horizontal_zoom_cursor {
    my ($self, $dir) = @_;
    return unless defined $dir;

    my $anchor_x = $self->{crosshair_x};
    return $self->_horizontal_zoom($dir) unless defined $anchor_x;

    my $current = $self->{current_visible_bars} || $self->{initial_visible_bars};
    my $total   = $self->{market_data}->size;
    return unless $total > 0;

    my $next = $self->_next_visible_bars($current, $dir);
    return if $next == $current;

    # Indice CONTINUO bajo el cursor con el mapeo X actual (incluye x_shift).
    my $cw_old     = $self->{candle_width} || ($self->{width} / $current);
    my $start_old  = defined $self->{view_start} ? $self->{view_start} : 0;
    my $xshift     = $self->{x_shift} || 0;
    my $idx_anchor = (($anchor_x - $xshift) / $cw_old) + $start_old;

    $self->_zoom_keep_anchor($next, $idx_anchor, $anchor_x);
}

# _y_axis_scale_drag($mouse_y, $dy, $target)
sub _y_axis_scale_drag {
    my ($self, $mouse_y, $dy, $target) = @_;
    $target ||= 'price';

    if ($target eq 'atr') {
        $self->_atr_zoom_drag($mouse_y, $dy);
        return;
    }

    my $scale = $self->{price_scale};
    return unless $scale && defined $mouse_y && defined $dy && $dy != 0;

    $self->{auto_scale} = 0;
    # FIX-4c: el drag viene de la franja del eje Y; mouse_y es la coordenada Y
    # real del canvas, que puede estar dentro del rango 0..price_height. Si por
    # algun motivo queda fuera, la acotamos al centro del panel para que el ancla
    # del zoom sea estable y no cause un salto de rango.
    my $ph = $self->{price_height} || ($scale->{height} || 400);
    $mouse_y = $ph / 2 if $mouse_y < 0 || $mouse_y > $ph;

    # FIX-5: _ensure_scale_covers_data ya fue llamado en Button-1 al iniciar
    # el drag; no repetirlo en cada evento Motion para evitar el salto visual
    # en el primer pixel y el reencaje que revierte el zoom del usuario.
    Market::Core::VerticalScaleZoom::apply_drag(
        $scale, $mouse_y, $dy, $self->_vertical_zoom_opts('price'),
    );
    $scale->{scale_drag_active} = 1;
    $self->_request_render_throttled();
}

# _in_time_axis($y) -> bool
# Franja del eje de tiempo (debajo del ATR): zoom horizontal estilo TradingView.
sub _in_time_axis {
    my ($self, $y) = @_;
    return 0 unless defined $y;
    my $top = $self->_time_axis_y;
    my $h   = $self->{time_axis_height} || 42;
    return ($y >= $top && $y < $top + $h) ? 1 : 0;
}

# _route_wheel_zoom($dir, $ctrl)
# Enruta la rueda segun la zona bajo el cursor (estilo TradingView):
#   - Panel ATR          -> zoom vertical del ATR (escala propia, no precio).
#   - Eje Y de precios   -> zoom vertical del precio.
#   - Precio / eje tiempo -> zoom horizontal.
#   - Ctrl               -> zoom horizontal anclado al cursor.
sub _route_wheel_zoom {
    my ($self, $dir, $ctrl, $event_name, $seq, $dt) = @_;
    return unless defined $dir;

    # Resincroniza el tamano real ANTES de decidir la zona: evita el "salto
    # vertical" en Linux/X11 por <Configure> retrasado/incompleto.
    $self->_sync_canvas_geometry();

    my $x = $self->{crosshair_x};
    my $y = $self->{crosshair_y};
    my $canvas = $self->{canvas};
    my $canvas_w_before = eval { $canvas ? $canvas->width : undef };
    my $canvas_h_before = eval { $canvas ? $canvas->height : undef };
    my $price_strip_before = defined $x && defined $y ? ($self->_in_price_y_axis_strip($x, $y) ? 1 : 0) : 'undef';
    my $atr_strip_before = defined $x && defined $y ? ($self->_in_atr_y_axis_strip($x, $y) ? 1 : 0) : 'undef';
    $self->_dbg_wheel('ROUTE_CHECK',
        event        => $event_name,
        seq          => $seq,
        dt           => $dt,
        dir          => $dir,
        ctrl         => $ctrl ? 1 : 0,
        x            => $x,
        y            => $y,
        atr_strip    => $atr_strip_before,
        price_strip  => $price_strip_before,
        price_height => $self->{price_height},
        atr_height   => $self->{atr_height},
        strip_w      => $self->{price_scale}{y_axis_strip_w},
        width        => $self->{width},
        canvas_w     => $canvas_w_before,
        canvas_h     => $canvas_h_before,
    );
    my $before = {
        offset               => $self->{offset},
        current_visible_bars => $self->{current_visible_bars},
        x_shift              => $self->{x_shift},
        view_start           => $self->{view_start},
    };

    my $branch = 'horizontal';
    if ($ctrl) {
        $branch = 'horizontal_cursor';
        $self->_dbg_wheel('ROUTE',
            event  => $event_name,
            seq    => $seq,
            branch => $branch,
            dir    => $dir,
            ctrl   => 1,
        );
        $self->_horizontal_zoom_cursor($dir);
    }
    else {
        if (defined $x && defined $y && $self->_in_atr_y_axis_strip($x, $y)) {
            $branch = 'vertical_atr';
            $self->_dbg_wheel('ROUTE',
                event  => $event_name,
                seq    => $seq,
                branch => $branch,
                dir    => $dir,
                ctrl   => 0,
            );
            $self->_atr_zoom_wheel($dir);
        }
        elsif (defined $x && defined $y && $self->_in_price_y_axis_strip($x, $y)) {
            $branch = 'vertical_price';
            $self->_dbg_wheel('ROUTE',
                event  => $event_name,
                seq    => $seq,
                branch => $branch,
                dir    => $dir,
                ctrl   => 0,
            );
            $self->_vertical_zoom_scale($dir);
        }
        else {
            $branch = 'horizontal';
            $self->_dbg_wheel('ROUTE',
                event  => $event_name,
                seq    => $seq,
                branch => $branch,
                dir    => $dir,
                ctrl   => 0,
            );
            $self->_horizontal_zoom($dir);
        }
    }

    my $canvas_w_after = eval { $canvas ? $canvas->width : undef };
    my $canvas_h_after = eval { $canvas ? $canvas->height : undef };
    my $price_strip = defined $x && defined $y ? ($self->_in_price_y_axis_strip($x, $y) ? 1 : 0) : 'undef';
    my $atr_strip = defined $x && defined $y ? ($self->_in_atr_y_axis_strip($x, $y) ? 1 : 0) : 'undef';
    my $after = {
        offset               => $self->{offset},
        current_visible_bars => $self->{current_visible_bars},
        x_shift              => $self->{x_shift},
        view_start           => $self->{view_start},
    };

    if ($self->_wheel_debug_enabled()) {
        $self->_wheel_debug_log(sprintf(
            "WHEEL_ROUTE event=%s seq=%s dt=%s dir=%s ctrl=%s branch=%s x=%s y=%s crosshair=(%s,%s) canvas_before=(%s,%s) canvas_after=(%s,%s) self=(%s,%s) price_strip_before=%s atr_strip_before=%s price_strip_after=%s atr_strip_after=%s before{offset=%s visible=%s x_shift=%s view_start=%s} after{offset=%s visible=%s x_shift=%s view_start=%s}\n",
            defined $event_name ? $event_name : 'unknown',
            $self->_wheel_debug_value($seq),
            $self->_wheel_debug_value($dt),
            $self->_wheel_debug_value($dir),
            $ctrl ? 1 : 0,
            $branch,
            $self->_wheel_debug_value($x),
            $self->_wheel_debug_value($y),
            $self->_wheel_debug_value($self->{crosshair_x}),
            $self->_wheel_debug_value($self->{crosshair_y}),
            $self->_wheel_debug_value($canvas_w_before),
            $self->_wheel_debug_value($canvas_h_before),
            $self->_wheel_debug_value($canvas_w_after),
            $self->_wheel_debug_value($canvas_h_after),
            $self->_wheel_debug_value($self->{width}),
            $self->_wheel_debug_value($self->{height}),
            $price_strip_before,
            $atr_strip_before,
            $price_strip,
            $atr_strip,
            $self->_wheel_debug_value($before->{offset}),
            $self->_wheel_debug_value($before->{current_visible_bars}),
            $self->_wheel_debug_value($before->{x_shift}),
            $self->_wheel_debug_value($before->{view_start}),
            $self->_wheel_debug_value($after->{offset}),
            $self->_wheel_debug_value($after->{current_visible_bars}),
            $self->_wheel_debug_value($after->{x_shift}),
            $self->_wheel_debug_value($after->{view_start}),
        ));
    }
}

# _vertical_zoom_scale($dir) — solo precio (ATR usa ATRPanelZoom).
sub _vertical_zoom_scale {
    my ($self, $dir) = @_;
    return unless defined $dir;

    my $scale = $self->{price_scale};
    return unless $scale;

    $self->{auto_scale} = 0;

    my $y = $self->{crosshair_y};
    return unless defined $y;

    # FIX-4: si el cursor esta en la franja del eje Y (no en el area del grafico),
    # crosshair_y es una coordenada dentro de la franja (ancho ~66px) que NO
    # representa una posicion vertical util para anclar el zoom. En ese caso
    # usamos la coordenada Y real del cursor dentro del panel de precios, que es
    # la misma Y pero en coordenadas del canvas. Si ademas la Y cae fuera del
    # rango 0..price_height, la acotamos al centro del panel.
    my $ph = $self->{price_height} || 0;
    if ($y < 0 || $y > $ph) {
        $y = $ph / 2;
    }

    $self->_ensure_scale_covers_data('price');
    Market::Core::VerticalScaleZoom::apply_wheel(
        $scale, $y, $dir, $self->_vertical_zoom_opts('price'),
    );
    $self->request_render();
}

# _vertical_zoom($dir)
# $dir < 0 = zoom-in vertical  (velas mas grandes en Y, rango mas estrecho)
# $dir > 0 = zoom-out vertical (velas mas pequenas en Y, rango mas amplio)
# Desactiva auto-escala para que el efecto persista.
#
# Zoom anclado al cursor: el precio que esta bajo el cursor permanece a la
# misma altura de pantalla tras el zoom (estilo TradingView). Si el cursor no
# esta dentro del panel de precios, se ancla al centro (comportamiento previo).
sub _vertical_zoom {
    my ($self, $dir) = @_;
    $self->_vertical_zoom_scale($dir);
}

sub _scroll_offset {
    my ($self, $delta) = @_;
    return unless defined $delta;
    $self->{offset} += $delta;
    $self->compute_window();
    $self->request_render();
}

# _pan_price_range_by_pixels($dy) -> $changed
# Desplaza el rango Y de precios segun el movimiento vertical del cursor (px).
sub _pan_price_range_by_pixels {
    my ($self, $dy) = @_;
    return 0 unless defined $dy && $dy != 0;
    return 0 unless $self->{price_scale};

    my $scale = $self->{price_scale};
    my ($min, $max) = $scale->get_range();
    my $range = $max - $min;
    return 0 if $range <= 0;

    my $usable = $scale->{height}
               - $scale->{padding_top}
               - $scale->{padding_bottom};
    return 0 if $usable <= 0;

    my $shift = ($dy / $usable) * $range;
    $scale->set_range($min + $shift, $max + $shift);
    return 1;
}

# _pan_drag($dx, $dy, $allow_vertical)
# Desplazamiento del viewport. Boton izquierdo: solo horizontal. Boton derecho:
# horizontal + vertical. No cambia AUTO/MANUAL.
sub _pan_drag {
    my ($self, $dx, $dy, $allow_vertical, $accum_key) = @_;
    my $changed = 0;

    if ($allow_vertical && defined $dy && $dy != 0) {
        # En AUTO la escala Y la gobierna SIEMPRE el encaje automatico (estilo
        # TradingView): el pan vertical no aplica y no se "congela" la escala.
        # Para mover la Y a mano, cambia a MANUAL con la tecla 'a'.
        if (!$self->{auto_scale}) {
            $changed = 1 if $self->_pan_price_range_by_pixels($dy);
        }
    }

    # --- Horizontal (scroll por velas) ---
    if (defined $dx && $dx != 0) {
        my $cw = $self->{candle_width} || 1;
        $cw = 1 if $cw <= 0;
        $accum_key ||= ($allow_vertical ? 'rmb_drag_accum' : 'drag_accum');
        $self->{$accum_key} = ($self->{$accum_key} || 0) + $dx;
        my $bars = int($self->{$accum_key} / $cw);
        if ($bars != 0) {
            $self->{$accum_key} -= $bars * $cw;
            $self->{offset}     += $bars;
            $self->compute_window();
            $changed = 1;
        }
    }

    $self->_request_render_throttled() if $changed;
}

# ── Timeframe y vista ─────────────────────────────────────────────────────────

# _zoom_out_cap($total) -> $cap
# Tope de zoom-out para la temporalidad activa (misma regla en todas las TF).
sub _zoom_out_cap {
    my ($self, $total) = @_;
    return $self->{max_visible_bars} unless $total > 0;

    my $fit_all = int($total * 1.15) + 1;
    my $plot_w  = $self->_plot_width();
    my $cw_cap  = ($plot_w > 0)
                ? int($plot_w / 0.4)
                : ($self->{width} && $self->{width} > 0)
                    ? int($self->{width} / 0.4)
                    : $self->{max_visible_bars};
    my $cap = $fit_all > $cw_cap ? $fit_all : $cw_cap;
    return $self->{max_visible_bars} if $cap > $self->{max_visible_bars};
    return $cap;
}

# _default_visible_bars($total) -> $visible
sub _default_visible_bars {
    my ($self, $total) = @_;
    my $visible = $self->{initial_visible_bars};
    $visible = $self->{max_visible_bars} if $visible > $self->{max_visible_bars};
    $visible = $self->{min_visible_bars} if $visible < $self->{min_visible_bars};
    my $cap = $self->_zoom_out_cap($total);
    $visible = $cap if $visible > $cap;
    # TF con pocas velas: mostrarlas todas en pantalla (evita whitespace por defecto).
    $visible = $total if $total > 0 && $visible > $total;
    return $visible;
}

# _save_tf_viewport()
# Guarda offset/zoom/escala Y del TF activo antes de cambiar de temporalidad.
sub _save_tf_viewport {
    my ($self) = @_;
    my $tf = $self->{active_tf} || '1m';
    my $state = {
        offset               => $self->{offset},
        x_shift              => $self->{x_shift},
        current_visible_bars => $self->{current_visible_bars},
        _auto_y_frozen       => $self->{_auto_y_frozen} ? 1 : 0,
    };
    if (!$self->{auto_scale} && $self->{price_scale}) {
        my ($min, $max) = $self->{price_scale}->get_range();
        $state->{y_min} = $min if defined $min;
        $state->{y_max} = $max if defined $max;
    }
    $self->{tf_viewport}{$tf} = $state;
}

# _load_tf_viewport($tf)
# Restaura el viewport del TF o aplica defaults unificados en la primera visita.
sub _load_tf_viewport {
    my ($self, $tf) = @_;
    my $total = $self->{market_data} ? $self->{market_data}->size : 0;
    return unless $total > 0;

    my $saved = $self->{tf_viewport}{$tf};
    if ($saved) {
        $self->{offset}               = $saved->{offset};
        $self->{x_shift}              = $saved->{x_shift};
        $self->{current_visible_bars} = $saved->{current_visible_bars};
        $self->{_auto_y_frozen}       = $saved->{_auto_y_frozen} ? 1 : 0;
        if (!$self->{auto_scale} && $self->{price_scale}
            && defined $saved->{y_min} && defined $saved->{y_max}
            && $saved->{y_max} > $saved->{y_min})
        {
            $self->{price_scale}->set_range($saved->{y_min}, $saved->{y_max});
        }
    }
    else {
        $self->{offset}         = 0;
        $self->{x_shift}        = 0;
        $self->{_auto_y_frozen} = 0;
        $self->{current_visible_bars} = $self->_default_visible_bars($total);
        if (!$self->{auto_scale} && $self->{price_scale}) {
            my ($min_p, $max_p) = $self->_auto_scale_y_range(0, $total - 1);
            if (defined $min_p && defined $max_p && $max_p > $min_p) {
                my $pad = ($max_p - $min_p) * 0.04;
                $pad = 1 unless $pad > 0;
                $self->{price_scale}->set_range($min_p - $pad, $max_p + $pad);
            }
        }
    }

    $self->_sync_viewport_to_total();
}

# _sync_viewport_to_total()
# Acota visible/offset al total del TF activo y aplica limites horizontales.
sub _sync_viewport_to_total {
    my ($self) = @_;
    my $total = $self->{market_data} ? $self->{market_data}->size : 0;
    return unless $total > 0;

    my $visible = $self->{current_visible_bars} || $self->{initial_visible_bars};
    $visible = $self->{max_visible_bars} if $visible > $self->{max_visible_bars};
    $visible = $self->{min_visible_bars} if $visible < $self->{min_visible_bars};
    my $cap = $self->_zoom_out_cap($total);
    $visible = $cap if $visible > $cap;
    $self->{current_visible_bars} = $visible;

    my $pw = $self->_plot_width();
    $self->_apply_candle_width(($pw > 0 ? $pw : $self->{width}) / $visible);
    $self->compute_window();
}

sub set_timeframe {
    my ($self, $tf) = @_;
    return unless $self->{market_data};
    return unless Market::MarketData->tf_minutes($tf);

    $self->_replay_exit() if $self->{replay_controller} && $self->{replay_controller}->is_active();

    my $prev_tf = $self->{active_tf} || '1m';
    $self->_save_tf_viewport() if $prev_tf ne $tf;

    $self->{atr_auto_scale} = 1;

    if ($self->{timeframe_manager} && $self->{timeframe_manager}->can('apply')) {
        return unless $self->{timeframe_manager}->apply($self->{market_data}, $tf);
    }
    else {
        $self->{market_data}->set_timeframe($tf);
        return unless ($self->{market_data}->size || 0) > 0;
    }

    $self->{active_tf} = $tf;
    if ($self->{timeframe_manager} && $self->{timeframe_manager}->can('set_active')) {
        $self->{timeframe_manager}->set_active($tf);
    }
    $self->{indicator_manager}->rebuild_all($self->{market_data})
        if $self->{indicator_manager};

    # Cambio de timeframe = cambio del dataset activo: invalidar y reconstruir la
    # cache de analisis (una sola vez) antes de renderizar.
    $self->invalidate_analysis_cache();
    $self->rebuild_analysis_cache();

    $self->_load_tf_viewport($tf);
    $self->_sync_infra_state();
    $self->render();
}

sub reset_view {
    my ($self) = @_;
    $self->_replay_exit() if $self->{replay_controller} && $self->{replay_controller}->is_active();
    $self->{tf_viewport}        = {};
    $self->{offset}             = 0;
    $self->{x_shift}            = 0;
    my $total = $self->{market_data} ? $self->{market_data}->size : 0;
    $self->{current_visible_bars} = $total > 0
        ? $self->_default_visible_bars($total)
        : $self->{initial_visible_bars};
    my $pw = $self->_plot_width();
    $self->_apply_candle_width(($pw > 0 ? $pw : $self->{width}) / $self->{current_visible_bars});
    $self->{auto_scale}     = 1;
    $self->{atr_auto_scale} = 1;
    $self->{_auto_y_frozen} = 0;
    $self->render();
}

sub _apply_candle_width {
    my ($self, $cw) = @_;
    return unless $cw && $cw > 0;
    $self->{candle_width}                = $cw;
    $self->{price_scale}->{candle_width} = $cw;
    $self->{atr_scale}->{candle_width}   = $cw;
}

sub _on_mouse_move {
    my ($self, $x, $y) = @_;
    return unless defined $x && defined $y;
    $self->{crosshair_x} = $x;
    $self->{crosshair_y} = $y;
    $self->_sync_infra_state();
    # Durante drag (escala o grafico) el motion ya hace render(); evitar parpadeo.
    return if $self->{y_axis_zoom_drag} || $self->{h_dragging} || $self->{rmb_dragging};
    $self->_draw_crosshair_all();
    $self->_draw_hud();
}

# _sync_canvas_geometry()
# Reconsulta el ancho/alto REAL del canvas (via winfo) y resincroniza el motor
# si difieren de los valores cacheados en $self->{width}/{height}. Existe
# porque en Linux/X11 el <Configure> puede llegar con retraso o en pasos
# intermedios mientras el WM termina de maximizar la ventana (en Windows no
# pasa esto). Si width/height quedan desfasados aunque sea por pocos pixeles,
# la franja del eje Y (width - strip_w) se corre hacia el area del grafico y
# un giro de rueda normal se clasifica por error como "zoom vertical".
# Se llama SIEMPRE antes de decidir la zona de un evento de rueda.
sub _sync_canvas_geometry {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    my $w = eval { $canvas->width  };
    my $h = eval { $canvas->height };
    return unless $w && $h && $w > 0 && $h > 0;
    $self->resize($w, $h) if $w != $self->{width} || $h != $self->{height};
}

1;
