package Market::Overlays::ZigZagMTF2DavidOverlay;

# =============================================================================
# Market::Overlays::ZigZagMTF2DavidOverlay
#
# Portado desde Proyecto_David/Market/Overlays/ZigZagMTF2.pm
# Adaptaciones para Kevin:
#   - Package renombrado a ZigZagMTF2DavidOverlay.
#   - TAG cambiado a 'david_zzmtf2' (evita colision con tags legacy de Kevin).
#   - sub render() reemplazada por sub draw(%args).
#   - Se agrega clear($canvas) para _draw_overlays.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'david_zzmtf2';

use constant {
    C_UP     => '#00e676',
    C_DOWN   => '#ff1744',
    C_FIBO   => '#00e676',
    C_LABEL  => '#2979ff',
    LINE_WIDTH      => 2,
    FIBO_LINE_WIDTH => 1,
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source      => $args{source},
        show_zigzag => $args{show_zigzag} // 1,
        show_fibo   => $args{show_fibo}   // 0,
        label_left  => $args{label_left}  // 1,
        enabled     => 0,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

# draw(%args): contrato del render loop de Kevin.
sub draw {
    my ( $self, %args ) = @_;
    my $canvas = $args{canvas};
    my $scale  = $args{scale};
    return unless $canvas && $scale;

    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;

    $self->_render_zigzag( $canvas, $scale, $src ) if $self->{show_zigzag};
    $self->_render_fibo( $canvas, $scale, $src )    if $self->{show_fibo};
}

sub clear {
    my ( $self, $canvas ) = @_;
    $canvas->delete(TAG) if $canvas;
}

# _price_in_range: verifica si un precio está dentro del rango visible del scale.
# Scales.pm de Kevin expone {min_value} y {max_value} directamente.
sub _price_in_range {
    my ( $scale, $price ) = @_;
    return defined($price)
        && $price >= $scale->{min_value}
        && $price <= $scale->{max_value};
}

# _visible_bars: número de barras visibles en el viewport.
# Scales.pm de Kevin usa {width} y {candle_width}; no existe {visible_bars}.
sub _visible_bars {
    my ($scale) = @_;
    my $cw = $scale->{candle_width} || 8;
    return int( ( $scale->{width} || 800 ) / $cw ) + 1;
}

sub _render_zigzag {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_segments');

    # Scales.pm de Kevin: start_index es el borde izquierdo del viewport.
    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);
    my $max_idx = $scale->{draw_end_index};
    $max_idx = $off + $vb if !defined $max_idx;

    my $segments = $src->get_segments;
    return unless $segments && @$segments;

    for my $s (@$segments) {
        next if !defined $s->{from_index} || !defined $s->{to_index};
        next if $s->{from_index} > $max_idx;
        next if $s->{to_index} < $off || $s->{from_index} > $off + $vb;
        next unless _price_in_range($scale, $s->{from_price})
                 || _price_in_range($scale, $s->{to_price});

        my $to_i = $s->{to_index};
        $to_i = $max_idx if $to_i > $max_idx;

        my $x1 = $scale->index_to_center_x( $s->{from_index} );
        my $y1 = $scale->value_to_y( $s->{from_price} );
        my $x2 = $scale->index_to_center_x( $to_i );
        my $y2 = $scale->value_to_y( $s->{to_price} );

        my $color = ( $s->{dir} eq 'up' ) ? C_UP : C_DOWN;

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => LINE_WIDTH,
            -tags  => [TAG] );
    }
}

sub _render_fibo {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_fibo_levels');
    my $levels = $src->get_fibo_levels;
    return unless $levels && @$levels;

    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);
    my $x_right_edge = $scale->index_to_center_x( $off + $vb );

    for my $lvl (@$levels) {
        next unless _price_in_range($scale, $lvl->{price});

        my $x1 = $scale->index_to_center_x( $lvl->{from_index} );
        my $y  = $scale->value_to_y( $lvl->{price} );

        my $x2 = $x_right_edge > $x1 ? $x_right_edge : $x1;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill  => C_FIBO,
            -width => FIBO_LINE_WIDTH,
            -tags  => [TAG] );

        my $label = sprintf( "%.3f (%.2f)", $lvl->{ratio}, $lvl->{price} );
        my ( $lx, $anchor ) = $self->{label_left}
            ? ( $x1 - 4, 'e' )
            : ( $x2 + 4, 'w' );

        $canvas->createText( $lx, $y,
            -text   => $label,
            -fill   => C_LABEL,
            -anchor => $anchor,
            -font   => [ '', 8 ],
            -tags   => [TAG] );
    }
}

1;
