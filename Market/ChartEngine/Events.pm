package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Events
# =============================================================================
# Bindings de canvas, rueda y despacho de eventos de entrada.
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

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
        if ($self->{_replay_select_mode}) {
            $self->_replay_pick_from_canvas($x, $y);
            return Tk::break;
        }
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
    $mw->bind('<KeyPress-s>' => sub { $self->_replay_select_start(); });
    $mw->bind('<KeyPress-S>' => sub { $self->_replay_select_start(); });
    $mw->bind('<space>'      => sub { $self->_replay_toggle_play(); });
    $mw->bind('<KeyPress-bracketright>' => sub { $self->_replay_step_forward(); });
    $mw->bind('<KeyPress-bracketleft>'  => sub { $self->_replay_step_backward(); });
    $mw->bind('<Shift-KeyPress-bracketright>' => sub { $self->_replay_fast_forward(); });
    $mw->bind('<Escape>' => sub { $self->_replay_exit(); });

    $mw->focus();
}

# build_control_panel($main_window)
# Barra Perl/Tk con controles de Replay (spec §3) y toggles de overlays (spec §4.5).

1;
