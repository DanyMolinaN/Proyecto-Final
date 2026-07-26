package Market::Overlays::SMCStructures2Overlay;

# =============================================================================
# Market::Overlays::SMCStructures2Overlay
#
# Portado desde Proyecto_David/Market/Overlays/SMC_Structures2.pm.
# Recorte deliberado: el original dibuja BOS/CHoCH, HH/HL/LH/LL, EQH/EQL,
# Trend Bars, Strong/Weak H-L, Premium/Discount y MTF Levels ademas de FVG y
# Order Blocks -- Kevin ya tiene esas otras funciones funcionando por su
# cuenta (StructureOverlay/LiquidityOverlay), asi que este overlay SOLO
# porta lo pedido: FVG y Order Blocks (Swing + Internal). El indicador
# fuente (SMCStructures2) sigue calculando todo lo demas internamente (es
# necesario para que Order Blocks funcione), simplemente no se dibuja aqui.
#
# Adaptaciones:
#   - TAG con prefijo smc2_ (evita colision con overlay_fvg/overlay_order_block
#     legacy de Kevin).
#   - render($canvas,$scale) -> draw(%args).
#   - $scale->{offset} -> $scale->{start_index}; $scale->{visible_bars} ->
#     calculado desde width/candle_width; $scale->_plot_w -> width menos
#     y_axis_strip_w; $scale->value_in_range()/{min_val}/{max_val} ->
#     _price_in_range() usando min_value/max_value (mismo patron que los
#     demas overlays portados).
# =============================================================================

use strict;
use warnings;

use constant TAG        => 'smc2_ob_fvg';
use constant TAG_LABELS => 'smc2_ob_fvg_labels';
sub tag        { return TAG; }
sub tag_labels { return TAG_LABELS; }

use constant {
    C_UP      => '#26a69a',
    C_DOWN    => '#ef5350',
    C_FVG_MIT => '#787b86',
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source           => $args{source},
        show_fvg         => $args{show_fvg}         // 1,
        show_ob_swing    => $args{show_ob_swing}    // 0,   # default off, igual que David (swOBCntInp)
        show_ob_internal => $args{show_ob_internal} // 1,   # default on,  igual que David (intOBCntInp)
        ob_max_swing     => $args{ob_max_swing}     // 5,
        ob_max_internal  => $args{ob_max_internal}  // 5,
        enabled          => 0,
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

sub _plot_w {
    my ($scale) = @_;
    return ( $scale->{width} || 800 ) - ( $scale->{y_axis_strip_w} // 66 );
}

sub draw {
    my ( $self, %args ) = @_;
    my $canvas = $args{canvas};
    my $scale  = $args{scale};
    return unless $canvas && $scale;

    $canvas->delete(TAG);
    $canvas->delete(TAG_LABELS);

    my $src = $self->{source};
    return unless $src;

    my @placed;

    $self->_render_order_blocks( $canvas, $scale, $src, \@placed, 'swing' )
        if $self->{show_ob_swing} && $src->can('get_swing_order_blocks');
    $self->_render_order_blocks( $canvas, $scale, $src, \@placed, 'internal' )
        if $self->{show_ob_internal} && $src->can('get_internal_order_blocks');
    $self->_render_fvgs( $canvas, $scale, $src, \@placed )
        if $self->{show_fvg} && $src->can('get_fvgs');
}

sub clear {
    my ( $self, $canvas ) = @_;
    return unless $canvas;
    $canvas->delete(TAG);
    $canvas->delete(TAG_LABELS);
}

sub _render_fvgs {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $fvgs = $src->get_fvgs or return;
    my $last_known = $src->processed_last;
    my $off    = $scale->{start_index} // 0;
    my $vb     = _visible_bars($scale);
    my $plot_w = _plot_w($scale);

    for my $f (@$fvgs) {
        next if $f->{state} eq 'deleted';

        my $right_idx = $last_known;

        next if $right_idx      < $off;
        next if $f->{idx_start} > $off + $vb;
        next unless _price_in_range( $scale, $f->{top} )
                 || _price_in_range( $scale, $f->{bottom} )
                 || ( $f->{bottom} < $scale->{min_value}
                   && $f->{top}    > $scale->{max_value} );

        my $is_mitigated = ( $f->{state} eq 'mitigated' );
        my $base = $is_mitigated ? C_FVG_MIT : ( $f->{dir} eq 'bull' ? C_UP : C_DOWN );
        my $fill = _mix( $base, $is_mitigated ? 0.20 : 0.30 );

        my $x1 = $scale->index_to_center_x( $f->{idx_start} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $f->{top} );
        my $yb = $scale->value_to_y( $f->{bottom} );

        $canvas->createRectangle( $x1, $yt, $x2, $yb,
            -fill => $fill, -outline => $fill, -width => 0, -tags => [TAG] );

        if ( ( $yb - $yt ) >= 12 ) {
            my $tx = ( $x1 + $x2 ) / 2;
            $tx = 24 if $tx < 24;
            $self->_chip( $canvas, $tx, ( $yt + $yb ) / 2, 'FVG',
                -color => $base, -place => 'center',
                -font  => 'TkDefaultFont 6 bold', -placed => $placed );
        }
    }
}

sub _render_order_blocks {
    my ( $self, $canvas, $scale, $src, $placed, $scope ) = @_;
    my $obs = $scope eq 'swing' ? $src->get_swing_order_blocks : $src->get_internal_order_blocks;
    return unless $obs && @$obs;

    my $max = $scope eq 'swing' ? $self->{ob_max_swing} : $self->{ob_max_internal};
    my $off    = $scale->{start_index} // 0;
    my $vb     = _visible_bars($scale);
    my $plot_w = _plot_w($scale);
    my $right_idx = $off + $vb;

    my $n = 0;
    for my $ob (@$obs) {
        last if ++$n > $max;
        next unless defined $ob->{barIndex};
        next if $ob->{barIndex} > $off + $vb;

        next unless _price_in_range( $scale, $ob->{barHigh} )
                 || _price_in_range( $scale, $ob->{barLow} )
                 || ( $ob->{barLow} < $scale->{min_value} && $ob->{barHigh} > $scale->{max_value} );

        my $x1 = $scale->index_to_center_x( $ob->{barIndex} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $ob->{barHigh} );
        my $yb = $scale->value_to_y( $ob->{barLow} );

        my $base = ( $ob->{bias} eq 'bull' ) ? C_UP : C_DOWN;
        my $op   = $scope eq 'internal' ? 0.10 : 0.16;
        my $fill = _mix( $base, $op );

        $canvas->createRectangle( $x1, $yt, $x2, $yb,
            -fill => $fill, -outline => $base, -width => 1, -tags => [TAG] );
    }
}

sub _chip {
    my ( $self, $canvas, $cx, $cy, $text, %o ) = @_;
    my $color  = $o{-color} // '#d6dbe6';
    my $place  = $o{-place} // 'above';
    my $off    = defined $o{-offset} ? $o{-offset} : 9;
    my $font   = $o{-font} // 'TkDefaultFont 10 bold';
    my $placed = $o{-placed};
    my $pad    = 2;

    my $ty = $place eq 'below'  ? $cy + $off
           : $place eq 'center' ? $cy
           :                      $cy - $off;

    my $tid = $canvas->createText(
        $cx, $ty, -text => $text, -anchor => 'center', -font => $font,
        -fill => '#ffffff', -tags => [TAG, TAG_LABELS] );
    my @bb = $canvas->bbox($tid);
    return unless @bb;
    my ( $x1, $y1, $x2, $y2 ) = @bb;
    $x1 -= $pad; $x2 += $pad; $y1 -= 1; $y2 += 1;

    if ($placed) {
        my $dir   = $place eq 'below' ? 1 : -1;
        my $h     = ( $y2 - $y1 ) + 2;
        my $tries = 0;
        while ( $tries++ < 6 && _box_hits( [ $x1, $y1, $x2, $y2 ], $placed ) ) {
            my $shift = $dir * $h;
            $_ += $shift for ( $y1, $y2 );
            $canvas->move( $tid, 0, $shift );
        }
        push @$placed, [ $x1, $y1, $x2, $y2 ];
    }

    my $rid = $canvas->createRectangle(
        $x1, $y1, $x2, $y2,
        -fill => $color, -outline => $color, -width => 1,
        -stipple => 'gray50', -tags => [TAG, TAG_LABELS] );
    $canvas->lower( $rid, $tid );
    return [ $x1, $y1, $x2, $y2 ];
}

sub _box_hits {
    my ( $b, $list ) = @_;
    for my $o (@$list) {
        next if $b->[2] < $o->[0] || $b->[0] > $o->[2]
             || $b->[3] < $o->[1] || $b->[1] > $o->[3];
        return 1;
    }
    return 0;
}

sub _mix {
    my ( $hex, $op ) = @_;
    $op = 0 if $op < 0;
    $op = 1 if $op > 1;
    my ( $r, $g, $b ) = ( hex( substr( $hex, 1, 2 ) ),
                          hex( substr( $hex, 3, 2 ) ),
                          hex( substr( $hex, 5, 2 ) ) );
    my $f = 1 - $op;
    my ( $br, $bg, $bb ) = ( 214, 219, 230 );
    $r = int( $r + ( $br - $r ) * $f );
    $g = int( $g + ( $bg - $g ) * $f );
    $b = int( $b + ( $bb - $b ) * $f );
    return sprintf( '#%02x%02x%02x', $r, $g, $b );
}

1;
