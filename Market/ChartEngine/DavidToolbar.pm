package Market::ChartEngine::DavidToolbar;

# =============================================================================
# Market::ChartEngine::DavidToolbar
#
# Panel colapsable con los controles de las herramientas portadas de David:
#   - ZigZag Externo (ZigZagVP2David)
#   - ZigZag Interno (ZigZagMTF2David) + selector de temporalidad (12 botones)
#   - Fibonacci (FibonacciDavid) — activa modo manual al pulsar
#   - Liquidity (LiquidityDavid)
#
# Mecanismo de activacion (segun plan seccion 7.4):
#   - Los botones llaman directamente a $overlay_manager->enable($key) o
#     $overlay_manager->disable($key), luego $chart_engine->request_render().
#   - NO usa toggle() (no existe en OverlayManager de Kevin).
#   - La persistencia usa OverlaySettings::_default_values() pero NO schema()
#     para que los botones no aparezcan en el panel legacy de Kevin.
#
# Instanciacion: desde ChartEngine::setup(), al final, despues de registrar
# todos los indicadores y overlays David.
# =============================================================================

use strict;
use warnings;

# Paleta de colores del toolbar
use constant {
    BG_PANEL   => '#181c27',
    BG_BTN     => '#1e222d',
    BG_ACTIVE  => '#2a2e39',
    FG_NORMAL  => '#d1d4dc',
    FG_DIM     => '#8892a4',
    # Colores por herramienta (identidad visual)
    C_ZZVP2    => '#8e44ad',   # morado  — ZigZag Externo
    C_ZZMTF2   => '#2ecc71',   # verde   — ZigZag Interno
    C_FIB      => '#f39c12',   # dorado  — Fibonacci
    C_LIQ      => '#1abc9c',   # teal    — Liquidity
    C_TF_ON    => '#2979ff',   # azul    — temporalidad activa
    FONT_BTN   => 'Helvetica 9 bold',
    FONT_TF    => 'Helvetica 8',
    FONT_LABEL => 'Helvetica 9',
};

# Temporalidades disponibles para el ZigZag Interno
my @TIMEFRAMES = qw(1m 2m 3m 5m 10m 15m 30m 45m 1h 2h 3h 4h);

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        # Widget padre donde se monta el toolbar
        parent          => $args{parent},
        # Instancias del sistema de Kevin
        overlay_manager => $args{overlay_manager},
        chart_engine    => $args{chart_engine},
        # Referencias a indicadores David (para set_timeframe, set_mode, etc.)
        indicator_refs  => $args{indicator_refs}  || {},
        # Referencias a overlays David (para is_manual_mode, handle_click)
        overlay_refs    => $args{overlay_refs}    || {},
        # Referencia a OverlaySettings (opcional, para persistencia)
        overlay_settings => $args{overlay_settings},
        
        # Controlador de replay
        replay_controller => $args{replay_controller},

        # Estado interno de cada boton
        _state => {
            zigzag_vp2_david   => 0,
            zigzag_mtf2_david  => 0,
            fibonacci_david    => 0,
            liquidity_david    => 0,
            smc2_ob_fvg        => 0,
        },
        _current_tf      => '5m',   # temporalidad por defecto del ZigZag Int
        _toolbar_visible => 1,

        # Widgets (se almacenan para poder actualizar textos/colores)
        _btns => {},

        _select_armed => {},   # flags de un solo uso: 'avwap' => 1/0, 'anchored_vp' => 1/0
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# build(): construye y empaqueta todos los widgets Tk.
# Se llama desde ChartEngine::setup() despues de instanciar el objeto.
# -----------------------------------------------------------------------------
sub build {
    my ($self) = @_;
    my $parent = $self->{parent};
    return unless $parent;

    my $bg = BG_PANEL;
    my $fg = FG_NORMAL;

    # ── Frame exterior (siempre visible) ─────────────────────────────────────
    my $outer = $parent->Frame( -background => $bg )->pack(
        -side => 'top', -fill => 'x', -padx => 0, -pady => 0,
    );
    $self->{_outer_frame} = $outer;

    # ── Boton de colapso/expansion ────────────────────────────────────────────
    my $toggle_btn = $outer->Button(
        -text             => "\x{25BC} David Tools",
        -background       => BG_ACTIVE,
        -foreground       => $fg,
        -activebackground => '#363a45',
        -font             => FONT_BTN,
        -relief           => 'flat',
        -padx             => 8,
        -pady             => 3,
        -anchor           => 'w',
    )->pack( -side => 'top', -fill => 'x', -padx => 0, -pady => 0 );
    $self->{_toggle_btn} = $toggle_btn;

    # ── Frame colapsable con los controles ────────────────────────────────────
    my $controls = $outer->Frame( -background => $bg );
    $controls->pack( -side => 'top', -fill => 'x', -padx => 4, -pady => 2 );
    $self->{_controls_frame} = $controls;

    # Accion de colapso
    $toggle_btn->configure( -command => sub { $self->_toggle_toolbar($toggle_btn, $controls) } );

    # ── Fila 1: ZigZag Ext | ZigZag Int | Selector TF ────────────────────────
    my $row1 = $controls->Frame( -background => $bg )->pack(
        -side => 'top', -fill => 'x', -pady => 2,
    );
    $self->_build_toggle_btn( $row1, 'zigzag_vp2_david',  'ZigZag Ext', C_ZZVP2  );
    $self->_build_toggle_btn( $row1, 'zigzag_mtf2_david', 'ZigZag Int', C_ZZMTF2 );
    $self->_build_tf_selector($row1);

    # ── Fila 2: Fibonacci | Liquidity ─────────────────────────────────────────
    my $row2 = $controls->Frame( -background => $bg )->pack(
        -side => 'top', -fill => 'x', -pady => 2,
    );
    $self->_build_toggle_btn( $row2, 'fibonacci_david', 'Fibonacci', C_FIB );
    $self->_build_toggle_btn( $row2, 'liquidity_david', 'Liquidity', C_LIQ );

    # ── Fila 3: VWAP ────────────────────────────────────────────────────────
    my $row3 = $controls->Frame( -background => $bg )->pack(
        -side => 'top', -fill => 'x', -pady => 2,
    );
    $self->_build_toggle_btn( $row3, 'anchored_vwap_david', 'AVWAP', '#2962ff' );

    my $btn_avwap_auto = $row3->Button(
        -text => 'Auto', -background => BG_BTN, -foreground => '#26a69a',
        -font => FONT_TF, -relief => 'flat', -padx => 6, -pady => 2,
    )->pack( -side => 'left', -padx => 2 );
    my $btn_avwap_manual = $row3->Button(
        -text => 'Manual (clic vela)', -background => BG_BTN, -foreground => FG_DIM,
        -font => FONT_TF, -relief => 'flat', -padx => 6, -pady => 2,
    )->pack( -side => 'left', -padx => 2 );

    $btn_avwap_auto->configure( -command => sub {
        my $ind = $self->{indicator_refs}{avwap};
        $ind->set_mode('auto') if $ind && $ind->can('set_mode');
        $btn_avwap_auto->configure( -foreground => '#26a69a' );
        $btn_avwap_manual->configure( -foreground => FG_DIM );
        $self->{chart_engine}->request_render() if $self->{chart_engine};
    });
    $btn_avwap_manual->configure( -command => sub {
        my $ind = $self->{indicator_refs}{avwap};
        $ind->set_mode('manual') if $ind && $ind->can('set_mode');
        $self->{_select_armed}{avwap} = 1;   # se arma para el PROXIMO clic
        $btn_avwap_auto->configure( -foreground => FG_DIM );
        $btn_avwap_manual->configure( -foreground => '#ef5350' );
    });

    for my $band (qw(band1 band2 band3)) {
        my $label = 'D' . substr($band, -1);
        $row3->Button(
            -text => $label, -background => BG_BTN, -foreground => FG_DIM,
            -font => FONT_TF, -relief => 'flat', -padx => 4, -pady => 2,
            -command => sub {
                my $ov = $self->{overlay_refs}{avwap};
                $ov->set_flag("show_$band", !$ov->{"show_$band"}) if $ov;
                $self->{chart_engine}->request_render() if $self->{chart_engine};
            },
        )->pack( -side => 'left', -padx => 1 );
    }

    # ── Fila 4: AVP y Pivotes ───────────────────────────────────────────────
    my $row4 = $controls->Frame( -background => $bg )->pack(
        -side => 'top', -fill => 'x', -pady => 2,
    );
    $self->_build_toggle_btn( $row4, 'pivot_anchors_david', 'Pivotes', '#ffd700' );
    $self->_build_toggle_btn( $row4, 'anchored_vp_david', 'AVP', '#ffd700' );

    $row4->Label( -text => 'Filas:', -background => $bg, -foreground => FG_DIM, -font => FONT_TF )
        ->pack( -side => 'left', -padx => 4 );
    my $avp_scale = $row4->Scale(
        -from => 10, -to => 100, -resolution => 1, -orient => 'horizontal',
        -length => 90, -showvalue => 1, -font => FONT_TF,
        -command => sub {
            my ($val) = @_;
            my $ind = $self->{indicator_refs}{anchored_vp};
            $ind->set_row_count($val + 0) if $ind;
            $self->{chart_engine}->request_render() if $self->{chart_engine};
        },
    )->pack( -side => 'left', -padx => 2 );
    $avp_scale->set( $self->{indicator_refs}{anchored_vp}{row_count} // 24 );

    my $btn_avp_auto = $row4->Button(
        -text => 'Auto', -background => BG_BTN, -foreground => '#26a69a',
        -font => FONT_TF, -relief => 'flat', -padx => 6, -pady => 2,
    )->pack( -side => 'left', -padx => 2 );
    my $btn_avp_manual = $row4->Button(
        -text => 'Manual (clic vela)', -background => BG_BTN, -foreground => FG_DIM,
        -font => FONT_TF, -relief => 'flat', -padx => 6, -pady => 2,
    )->pack( -side => 'left', -padx => 2 );

    $btn_avp_auto->configure( -command => sub {
        my $ind = $self->{indicator_refs}{anchored_vp};
        $ind->set_mode('auto') if $ind;
        $self->{_select_armed}{anchored_vp} = 0;
        $btn_avp_auto->configure( -foreground => '#26a69a' );
        $btn_avp_manual->configure( -foreground => FG_DIM );
        $self->{chart_engine}->request_render() if $self->{chart_engine};
    });
    $btn_avp_manual->configure( -command => sub {
        my $ind = $self->{indicator_refs}{anchored_vp};
        $ind->set_mode('manual') if $ind;
        $self->{_select_armed}{anchored_vp} = 1;   # se arma para el PROXIMO clic
        $btn_avp_auto->configure( -foreground => FG_DIM );
        $btn_avp_manual->configure( -foreground => '#ef5350' );
    });

    # ── Fila 5: SMC Structures 2 ──────────────────────────────────────────────
    my $row5 = $controls->Frame( -background => $bg )->pack(
        -side => 'top', -fill => 'x', -pady => 2,
    );
    $self->_build_toggle_btn( $row5, 'smc2_ob_fvg', 'FVG', '#26a69a' );
    for my $pair ( ['ob_swing' => 'OB Swing'], ['ob_internal' => 'OB Internal'] ) {
        my ( $flag, $label ) = @$pair;
        $row5->Button(
            -text => $label, -background => BG_BTN, -foreground => FG_DIM,
            -font => FONT_TF, -relief => 'flat', -padx => 6, -pady => 2,
            -command => sub {
                my $ov = $self->{overlay_refs}{smc2};
                $ov->set_flag("show_$flag", !$ov->{"show_$flag"}) if $ov;
                $self->{chart_engine}->request_render() if $self->{chart_engine};
            },
        )->pack( -side => 'left', -padx => 2 );
    }

    return $self;
}

# -----------------------------------------------------------------------------
# _build_toggle_btn: crea un boton On/Off para un overlay David.
# El boton alterna entre estado activo (fondo coloreado) e inactivo (gris).
# -----------------------------------------------------------------------------
sub _build_toggle_btn {
    my ( $self, $parent_frame, $key, $label, $color ) = @_;
    my $bg = BG_PANEL;

    my $btn = $parent_frame->Button(
        -text             => "\x{25CF} $label",   # circulo relleno + etiqueta
        -background       => BG_BTN,
        -foreground       => FG_DIM,
        -activebackground => BG_ACTIVE,
        -font             => FONT_BTN,
        -relief           => 'flat',
        -padx             => 8,
        -pady             => 4,
        -width            => 12,
    )->pack( -side => 'left', -padx => 3, -pady => 1 );

    $self->{_btns}{$key} = { widget => $btn, color => $color, label => $label };

    $btn->configure( -command => sub {
        $self->_toggle_overlay($key, $btn, $color, $label);
    });
    return $btn;
}

# -----------------------------------------------------------------------------
# _build_tf_selector: 12 botones de temporalidad para el ZigZag Interno.
# Organizados en dos filas (botones compactos).
# -----------------------------------------------------------------------------
sub _build_tf_selector {
    my ( $self, $parent_frame ) = @_;
    my $bg = BG_PANEL;

    my $tf_outer = $parent_frame->Frame( -background => $bg )->pack(
        -side => 'left', -padx => 6,
    );

    $parent_frame->Label(
        -text       => 'TF:',
        -background => $bg,
        -foreground => FG_DIM,
        -font       => FONT_LABEL,
    )->pack( -in => $tf_outer, -side => 'left' );

    my $tf_grid = $tf_outer->Frame( -background => $bg )->pack(
        -side => 'left',
    );

    # Primera fila: 1m 2m 3m 5m 10m 15m
    my $tf_row1 = $tf_grid->Frame( -background => $bg )->pack( -side => 'top' );
    # Segunda fila: 30m 45m 1h 2h 3h 4h
    my $tf_row2 = $tf_grid->Frame( -background => $bg )->pack( -side => 'top' );

    $self->{_tf_btns} = {};
    my $idx = 0;
    for my $tf (@TIMEFRAMES) {
        my $row = $idx < 6 ? $tf_row1 : $tf_row2;
        my $is_active = ( $tf eq $self->{_current_tf} );

        my $b = $row->Button(
            -text             => $tf,
            -background       => $is_active ? C_TF_ON : BG_BTN,
            -foreground       => $is_active ? '#ffffff' : FG_DIM,
            -activebackground => BG_ACTIVE,
            -font             => FONT_TF,
            -relief           => 'flat',
            -padx             => 3,
            -pady             => 2,
            -width            => 4,
        )->pack( -side => 'left', -padx => 1, -pady => 1 );

        my $tf_copy = $tf;
        $b->configure( -command => sub { $self->_select_tf($tf_copy) } );
        $self->{_tf_btns}{$tf} = $b;
        $idx++;
    }
}

# =============================================================================
# Acciones de los botones
# =============================================================================

# Colapsa o expande el frame de controles.
sub _toggle_toolbar {
    my ( $self, $toggle_btn, $controls ) = @_;
    if ( $self->{_toolbar_visible} ) {
        $controls->packForget();
        $toggle_btn->configure( -text => "\x{25B2} David Tools" );
    }
    else {
        $controls->pack( -side => 'top', -fill => 'x', -padx => 4, -pady => 2 );
        $toggle_btn->configure( -text => "\x{25BC} David Tools" );
    }
    $self->{_toolbar_visible} = !$self->{_toolbar_visible};
}

# Alterna el estado de un overlay David.
sub _toggle_overlay {
    my ( $self, $key, $btn, $color, $label ) = @_;
    my $om = $self->{overlay_manager};
    my $ce = $self->{chart_engine};
    return unless $om && $ce;

    $self->{_state}{$key} = !$self->{_state}{$key};
    my $on = $self->{_state}{$key};

    if ($on) {
        $om->enable($key);
    }
    else {
        $om->disable($key);
    }

    # Fibonacci: al activar → modo manual (un click = ancla); al desactivar → off
    if ( $key eq 'fibonacci_david' ) {
        my $fib = $self->{indicator_refs}{fibonacci};
        if ( $fib && $fib->can('set_mode') ) {
            $fib->set_mode( $on ? 'manual' : 'off' );
            $fib->clear_manual_anchor if !$on && $fib->can('clear_manual_anchor');
        }
    }

    # Al activar: como David, solo render si ya hay datos calientes.
    # Rebuild solo si el indicador esta vacio o desfasado respecto al MD.
    if ($on) {
        my $ind_key = {
            zigzag_vp2_david  => 'zigzag_vp2',
            zigzag_mtf2_david => 'zigzag_mtf2',
            liquidity_david   => 'liquidity',
            fibonacci_david   => 'fibonacci',
            anchored_vwap_david => 'avwap',
            pivot_anchors_david => 'pivot_anchors',   
            anchored_vp_david   => 'anchored_vp',    
            smc2_ob_fvg         => 'smc2',

        }->{$key};
        my $ind = $ind_key ? $self->{indicator_refs}{$ind_key} : undef;
        my $md  = $ce->{market_data};
        if ( $ind && $md ) {
            my $im = $ce->{indicator_manager};
            my $reg_name = {
                zigzag_vp2  => 'zigzag_vp2_david',
                zigzag_mtf2 => 'zigzag_mtf2_david',
                liquidity   => 'liquidity_david',
                fibonacci   => 'fibonacci_david',
                avwap       => 'anchored_vwap_david',
                pivot_anchors => 'pivot_anchors_david',  
                anchored_vp   => 'anchored_vp_david',     
                smc2          => 'smc2',

            }->{$ind_key};

            my $needs = $self->_david_indicator_needs_recompute($ind, $md, $reg_name);
            if ($needs) {
                if ( $im && $reg_name && $im->can('rebuild_one') ) {
                    if ( $reg_name eq 'liquidity_david' ) {
                        # Liquidity depende de ambos ZigZag
                        for my $dep (qw(zigzag_vp2_david zigzag_mtf2_david)) {
                            my $dep_ind = $im->get($dep);
                            if ($self->_david_indicator_needs_recompute($dep_ind, $md, $dep)) {
                                $im->rebuild_one($dep, $md);
                            }
                        }
                    }
                    $ind->reset() if $ind->can('reset');
                    $ind->recompute($md, $self->{_pending_limit}{$reg_name});
                }
                elsif ( $ind->can('recompute') ) {
                    $ind->recompute($md);
                }
            }
        }
    }

    $btn->configure(
        -background => $on ? $color   : BG_BTN,
        -foreground => $on ? '#ffffff' : FG_DIM,
    );

    if ( my $os = $self->{overlay_settings} ) {
        $os->set( "show_$key", $on ? 1 : 0 );
        $os->save() if $os->can('save');
    }

    $ce->request_render();
}

# Cambia la temporalidad del ZigZag Interno (independiente del TF del chart).
sub _select_tf {
    my ( $self, $tf ) = @_;
    return if $tf eq $self->{_current_tf};

    # Actualizar visual: desactivar anterior, activar nuevo
    if ( my $old_btn = $self->{_tf_btns}{ $self->{_current_tf} } ) {
        $old_btn->configure( -background => BG_BTN, -foreground => FG_DIM );
    }
    if ( my $new_btn = $self->{_tf_btns}{$tf} ) {
        $new_btn->configure( -background => C_TF_ON, -foreground => '#ffffff' );
    }
    $self->{_current_tf} = $tf;

    my $ind = $self->{indicator_refs}{zigzag_mtf2};
    my $ce  = $self->{chart_engine};

    # ZigZagMTF2David expone set_resolution (no set_timeframe).
    if ( $ind && $ind->can('set_resolution') ) {
        $ind->set_resolution($tf);
        # Recalcular sobre el MarketData activo del chart
        if ( $ce && $ce->{market_data} && $ind->can('recompute') ) {
            $ind->recompute( $ce->{market_data} );
        }
    }
    elsif ( $ind && $ind->can('set_timeframe') ) {
        $ind->set_timeframe($tf);
    }

    if ( $self->{_state}{zigzag_mtf2_david} && $ce ) {
        $ce->request_render();
    }
}

sub _david_indicator_needs_recompute {
    my ( $self, $ind, $md, $reg_name ) = @_;
    return 1 unless $ind && $md;

    my $total = $md->can('size') ? ($md->size // 0) : 0;
    return 1 if $total <= 0;

    my $size = $total;
    my $rc = $self->{replay_controller};
    if ( $rc && $rc->can('visible_limit') ) {
        my $vl = $rc->visible_limit($total);
        $size = $vl if defined $vl && $vl >= 0 && $vl < $total;
    }

    my $tf = '';
    if ($reg_name && $reg_name eq 'zigzag_mtf2_david' && $ind->can('get_resolution')) {
        $tf = $ind->get_resolution() // '';
    }
    elsif ($md->can('active_tf')) {
        $tf = $md->active_tf() // '';
    }
    my $want = "$tf|$size";

    my $fp = $ind->{_kevin_computed_fp};
    return 0 if defined $fp && $fp eq $want;

    $ind->{_kevin_computed_fp} = $want;
    $self->{_pending_limit}{$reg_name} = $size;   # <-- guardamos el limite para el recompute
    return 1;
}

# =============================================================================
# API publica para Events.pm
# =============================================================================

# overlay_ref($key): devuelve la referencia al overlay David solicitado.
# Usado por Events.pm para obtener el overlay de Fibonacci y llamar
# handle_click / is_manual_mode.
sub overlay_ref {
    my ( $self, $key ) = @_;
    return $self->{overlay_refs}{$key};
}

# is_fibonacci_manual_mode: atajo para Events.pm.
sub is_fibonacci_manual_mode {
    my ($self) = @_;
    my $fib_ov = $self->{overlay_refs}{fibonacci};
    return 0 unless $fib_ov && $fib_ov->can('is_manual_mode');
    return $fib_ov->is_manual_mode();
}

# handle_fibonacci_click($index): atajo para Events.pm.
sub handle_fibonacci_click {
    my ( $self, $index ) = @_;
    my $fib_ov = $self->{overlay_refs}{fibonacci};
    return unless $fib_ov && $fib_ov->can('handle_click');
    $fib_ov->handle_click($index);
    $self->{chart_engine}->request_render() if $self->{chart_engine};
}

sub is_avwap_manual_mode {
    my ($self) = @_;
    return $self->{_select_armed}{avwap} ? 1 : 0;
}

sub handle_avwap_click {
    my ( $self, $index ) = @_;
    my $ov = $self->{overlay_refs}{avwap};
    return unless $ov && $ov->can('handle_click');
    $ov->handle_click($index);
    $self->{_select_armed}{avwap} = 0;   # desarma: el siguiente clic ya no ancla
    $self->{chart_engine}->request_render() if $self->{chart_engine};
}

sub is_anchored_vp_manual_mode {
    my ($self) = @_;
    return $self->{_select_armed}{anchored_vp} ? 1 : 0;
}

sub handle_anchored_vp_click {
    my ( $self, $index ) = @_;
    my $ov = $self->{overlay_refs}{anchored_vp};
    return unless $ov && $ov->can('handle_click');
    $ov->handle_click($index);
    $self->{_select_armed}{anchored_vp} = 0;
    $self->{chart_engine}->request_render() if $self->{chart_engine};
}

sub recompute_if_needed {
    my ( $self, $md ) = @_;
    return unless $md;
    my $im = $self->{chart_engine} && $self->{chart_engine}->{indicator_manager};
    return unless $im;

    my $ind = $im->get('zigzag_vp2_david');
    return unless $ind;
    if ( $self->_david_indicator_needs_recompute( $ind, $md, 'zigzag_vp2_david' ) ) {
        $ind->reset() if $ind->can('reset');
        $ind->recompute( $md, $self->{_pending_limit}{zigzag_vp2_david} );
    }
}

1;