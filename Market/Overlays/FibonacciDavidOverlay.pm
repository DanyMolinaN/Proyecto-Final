package Market::Overlays::FibonacciDavidOverlay;

# =============================================================================
# Market::Overlays::FibonacciDavidOverlay
#
# Portado desde Proyecto_David/Market/Overlays/Fibonacci.pm
# Adaptaciones para Kevin:
#   - Package renombrado a FibonacciDavidOverlay.
#   - TAG cambiado a 'david_fibonacci' (evita colision con FibonacciOverlay
#     legacy de Kevin que usa tags 'fib_line', 'fib_label', 'fib_level').
#   - sub render($canvas, $scale) reemplazada por sub draw(%args).
#   - Campos de Scales.pm corregidos para Kevin:
#       * $scale->{offset}        → $scale->{start_index}
#       * $scale->{visible_bars}  → _visible_bars($scale)
#       * $scale->value_in_range  → _price_in_range($scale, $price)
#   - handle_click($index): recibe indice de vela ya resuelto (lo resuelve
#     Events.pm via x_to_index antes de llamar este metodo).
#   - is_manual_mode(): usado por Events.pm para decidir si rutear clicks.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'david_fibonacci';

use constant {
    C_FIBO          => '#ffb300',   # ambar — diferente del fibo interno (lime)
    C_LABEL         => '#ffb300',
    C_ANCHOR        => '#ffffff',
    FIBO_LINE_WIDTH => 1,
    ANCHOR_MARKER_R => 4,
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source     => $args{source},         # Market::Indicators::FibonacciDavid
        label_left => $args{label_left} // 0, # 0 = etiqueta a la derecha
        # enabled: gestionado por OverlayManager (enable/disable directo)
        enabled    => 0,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

# is_manual_mode: consultado por Events.pm antes de rutear un click de canvas.
sub is_manual_mode {
    my ($self) = @_;
    my $src = $self->{source};
    return 0 unless $src && $src->can('get_mode');
    return $src->get_mode eq 'manual' ? 1 : 0;
}

# handle_click($index): activa el ancla manual en el indicador.
# Events.pm llama este metodo con el indice de vela ya resuelto via
# $scale->x_to_index($x).
sub handle_click {
    my ( $self, $index ) = @_;
    my $src = $self->{source};
    return unless $src;
    return unless $src->can('get_mode') && $src->get_mode eq 'manual';
    $src->set_manual_anchor($index);
}

# ─── Helpers de Scales.pm de Kevin ──────────────────────────────────────────

# _price_in_range: Scales.pm de Kevin expone {min_value}/{max_value};
# no tiene metodo value_in_range().
sub _price_in_range {
    my ( $scale, $price ) = @_;
    return defined($price)
        && $price >= $scale->{min_value}
        && $price <= $scale->{max_value};
}

# _visible_bars: Scales.pm de Kevin no tiene {visible_bars};
# se deriva de {width} / {candle_width}.
sub _visible_bars {
    my ($scale) = @_;
    my $cw = $scale->{candle_width} || 8;
    return int( ( $scale->{width} || 800 ) / $cw ) + 1;
}

# ─── Contrato del render loop de Kevin ──────────────────────────────────────

# draw(%args): llamado por Render.pm::_draw_overlays cuando el overlay esta
# activo (enabled=1). Recibe canvas y scale como named args.
sub draw {
    my ( $self, %args ) = @_;
    my $canvas = $args{canvas};
    my $scale  = $args{scale};
    return unless $canvas && $scale;

    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;
    return unless $src->can('get_mode');

    my $mode = $src->get_mode;
    return if $mode eq 'off';

    $self->_render_fibo( $canvas, $scale, $src );
    $self->_render_manual_anchor( $canvas, $scale, $src ) if $mode eq 'manual';
}

# clear($canvas): llamado por _draw_overlays cuando el overlay esta desactivado.
sub clear {
    my ( $self, $canvas ) = @_;
    $canvas->delete(TAG) if $canvas;
}

# ─── Dibujo interno ─────────────────────────────────────────────────────────

sub _render_fibo {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_fibo_levels');
    my $levels = $src->get_fibo_levels;
    return unless $levels && @$levels;

    # Scales.pm de Kevin: start_index es el borde izquierdo del viewport.
    my $off          = $scale->{start_index} // 0;
    my $vb           = _visible_bars($scale);
    my $x_right_edge = $scale->index_to_center_x( $off + $vb );

    for my $lvl (@$levels) {
        next unless _price_in_range( $scale, $lvl->{price} );

        my $x1 = $scale->index_to_center_x( $lvl->{from_index} );
        my $y  = $scale->value_to_y( $lvl->{price} );

        my $x2 = $x_right_edge > $x1 ? $x_right_edge : $x1;

        $canvas->createLine(
            $x1, $y, $x2 - 10, $y,
            -fill  => C_FIBO,
            -width => FIBO_LINE_WIDTH,
            -tags  => [TAG],
        );

        my $label = sprintf( "%.3f (%.2f)", $lvl->{ratio}, $lvl->{price} );
        my ( $lx, $anchor ) = $self->{label_left}
            ? ( $x1 - 4,    'e' )
            : ( $x2 - 155,  'w' );

        $canvas->createText(
            $lx, $y - 7,
            -text   => $label,
            -fill   => C_LABEL,
            -anchor => $anchor,
            -font   => [ '', 8 ],
            -tags   => [TAG],
        );
    }
}

# Marcador visual de la vela ancla (circulo blanco) para modo manual.
sub _render_manual_anchor {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_manual_anchor');
    my $anchor = $src->get_manual_anchor;
    return unless defined $anchor;

    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);
    return if $anchor < $off || $anchor > $off + $vb;

    my $levels = $src->can('get_fibo_levels') ? $src->get_fibo_levels : undef;
    return unless $levels && @$levels;

    # El primer nivel (ratio 0) esta al precio del ancla (from_price).
    my $anchor_price = $levels->[0]{price};
    return unless _price_in_range( $scale, $anchor_price );

    my $x = $scale->index_to_center_x($anchor);
    my $y = $scale->value_to_y($anchor_price);

    $canvas->createOval(
        $x - ANCHOR_MARKER_R, $y - ANCHOR_MARKER_R,
        $x + ANCHOR_MARKER_R, $y + ANCHOR_MARKER_R,
        -outline => C_ANCHOR,
        -width   => 2,
        -tags    => [TAG],
    );
}

1;
