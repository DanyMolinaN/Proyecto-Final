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

        # Estado interno de cada boton
        _state => {
            zigzag_vp2_david   => 0,
            zigzag_mtf2_david  => 0,
            fibonacci_david    => 0,
            liquidity_david    => 0,
        },
        _current_tf      => '5m',   # temporalidad por defecto del ZigZag Int
        _toolbar_visible => 1,

        # Widgets (se almacenan para poder actualizar textos/colores)
        _btns => {},
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
                    $im->rebuild_one($reg_name, $md);
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

# True si hay que recalcular (vacio o size/tf distinto al ultimo compute).
# En replay el size esta recortado: exigir buffer EXACTO (nunca >=), si no
# se reutilizarian segmentos calculados con velas futuras.
sub _david_indicator_needs_recompute {
    my ( $self, $ind, $md, $reg_name ) = @_;
    return 1 unless $ind && $md;

    my $size = $md->can('size') ? ($md->size // 0) : 0;
    return 1 if $size <= 0;

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

    # Sin fingerprint: caliente solo si el buffer coincide EXACTO con size
    if ($ind->can('get_segments')) {
        my $segs = $ind->get_segments || [];
        my $buf  = $ind->{_c} || [];
        if (@$segs && @$buf == $size) {
            $ind->{_kevin_computed_fp} = $want;
            return 0;
        }
    }
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

1;
