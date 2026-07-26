package Market::Overlays::PivotAnchorsDavidOverlay;

# Portado desde Proyecto_David/Market/Overlays/PivotAnchors.pm.
# Adaptaciones: render($canvas,$scale) -> draw(%args); $scale->{offset} ->
# $scale->{start_index}; $scale->{visible_bars} -> calculado desde width/
# candle_width; $scale->value_in_range() -> _price_in_range() (min_value/
# max_value, igual que AnchoredVWAPDavidOverlay). TAG con prefijo david_.

use strict;
use warnings;

use constant TAG => 'david_pivot_anchors';

use constant {
    C_HIGH => '#ef5350',
    C_LOW  => '#26a69a',
    MARKER_R      => 4,
    MARKER_OFFSET => 10,
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source => $args{source},
        show   => $args{show} // 1,
        enabled => 0,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

sub _price_in_range {
    my ( $scale, $price ) = @_;
    return defined($price)
        && $price >= $scale->{min_value}
        && $price <= $scale->{max_value};
}

sub _visible_bars {
    my ($scale) = @_;
    my $cw = $scale->{candle_width} || 8;
    return int( ( $scale->{width} || 800 ) / $cw ) + 1;
}

sub draw {
    my ( $self, %args ) = @_;
    my $canvas = $args{canvas};
    my $scale  = $args{scale};
    return unless $canvas && $scale;

    $canvas->delete(TAG);
    return unless $self->{show};

    my $src = $self->{source};
    return unless $src && $src->can('get_pivots');

    my $pivots = $src->get_pivots;
    return unless $pivots && @$pivots;

    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);
    my $view_from = $off;
    my $view_to   = $off + $vb;

    for my $p (@$pivots) {
        next if $p->{index} < $view_from || $p->{index} > $view_to;
        next unless _price_in_range( $scale, $p->{price} );

        my $x = $scale->index_to_center_x( $p->{index} );
        my $y = $scale->value_to_y( $p->{price} );

        if ( $p->{type} eq 'high' ) {
            $self->_draw_triangle_down( $canvas, $x, $y - MARKER_OFFSET, C_HIGH );
        } else {
            $self->_draw_triangle_up( $canvas, $x, $y + MARKER_OFFSET, C_LOW );
        }
    }
}

sub clear {
    my ( $self, $canvas ) = @_;
    $canvas->delete(TAG) if $canvas;
}

sub _draw_triangle_down {
    my ( $self, $canvas, $x, $y, $color ) = @_;
    my $r = MARKER_R;
    $canvas->createPolygon(
        $x - $r, $y - $r, $x + $r, $y - $r, $x, $y + $r,
        -fill => $color, -outline => $color, -tags => [TAG],
    );
}

sub _draw_triangle_up {
    my ( $self, $canvas, $x, $y, $color ) = @_;
    my $r = MARKER_R;
    $canvas->createPolygon(
        $x - $r, $y + $r, $x + $r, $y + $r, $x, $y - $r,
        -fill => $color, -outline => $color, -tags => [TAG],
    );
}

1;
