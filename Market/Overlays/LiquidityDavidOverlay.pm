package Market::Overlays::LiquidityDavidOverlay;

# =============================================================================
# Market::Overlays::LiquidityDavidOverlay
#
# Portado desde Proyecto_David/Market/Overlays/Liquidity.pm
# Adaptaciones para Kevin:
#   - Package renombrado a LiquidityDavidOverlay.
#   - TAGs cambiados a 'david_liquidity' y 'david_liquidity_labels'
#     (evita colision con LiquidityOverlay legacy de Kevin, que usa
#     'liq_eqh', 'liq_eql', 'liq_line', 'liq_label', 'liq_zone').
#   - sub render($canvas,$scale) reemplazada por sub draw(%args).
#   - Campos de Scales.pm corregidos para Kevin:
#       * $scale->{offset}        → $scale->{start_index}
#       * $scale->{visible_bars}  → _visible_bars($scale)
#       * $scale->value_in_range  → _price_in_range($scale, $price)
#       * $scale->_plot_w         → _plot_w($scale)
#         (David tenia metodo _plot_w; Kevin lo expone via {width} y
#          {y_axis_strip_w})
# =============================================================================

use strict;
use warnings;

use constant TAG        => 'david_liquidity';
use constant TAG_LABELS => 'david_liquidity_labels';

sub tag        { return TAG; }
sub tag_labels { return TAG_LABELS; }

use constant {
    C_BSL    => '#ef5350',   # rojo    (Buy Side Liquidity)
    C_SSL    => '#26a69a',   # verde   (Sell Side Liquidity)
    C_EQ     => '#7e57c2',   # violeta (EQH/EQL)
    C_GRAB   => '#ff9800',   # naranja (Liquidity Grab)
    C_RUN    => '#4f8cff',   # azul    (Liquidity Run)
    C_TREND  => '#555555',   # gris    (trend line — ajustado para fondo oscuro)
    MAX_LINES  => 6,         # niveles BSL/SSL resting dibujados (mas recientes)
    MAX_EVENTS => 50,        # eventos recientes considerados por render
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source         => $args{source},
        swing_source   => $args{swing_source},  # ZigZagMTF2David (swings + trendline)
        show_swing     => $args{show_swing}     // 1,
        show_trendline => $args{show_trendline} // 1,
        show_bsl       => $args{show_bsl}       // 1,
        show_ssl       => $args{show_ssl}       // 1,
        show_eqh       => $args{show_eqh}       // 1,
        show_eql       => $args{show_eql}       // 1,
        show_sweeps    => $args{show_sweeps}    // 1,
        show_grabs     => $args{show_grabs}     // 1,
        show_runs      => $args{show_runs}      // 1,
        # enabled: gestionado por OverlayManager (enable/disable directo)
        enabled        => 0,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
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

# _plot_w: ancho del area de dibujo (total menos la tira del eje Y derecho).
# David tenia $scale->_plot_w(); Kevin expone los campos necesarios directamente.
sub _plot_w {
    my ($scale) = @_;
    my $strip = $scale->{y_axis_strip_w} || 66;
    return ( $scale->{width} || 800 ) - $strip;
}

# ─── Contrato del render loop de Kevin ──────────────────────────────────────

# draw(%args): llamado por Render.pm::_draw_overlays cuando enabled=1.
sub draw {
    my ( $self, %args ) = @_;
    my $canvas = $args{canvas};
    my $scale  = $args{scale};
    return unless $canvas && $scale;

    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;

    my @placed;   # cajas [x1,y1,x2,y2] ya colocadas (anti-solape de etiquetas)
    my $swing_src = $self->{swing_source};
    $self->_render_trendline( $canvas, $scale, $swing_src )    if $self->{show_trendline} && $swing_src;
    $self->_render_swings( $canvas, $scale, $swing_src )       if $self->{show_swing}     && $swing_src;
    $self->_render_levels( $canvas, $scale, $src, \@placed );
    $self->_render_equals( $canvas, $scale, $src, \@placed )
        if $self->{show_eqh} || $self->{show_eql};
    $self->_render_events( $canvas, $scale, $src, \@placed );
}

# clear($canvas): llamado cuando el overlay esta desactivado.
sub clear {
    my ( $self, $canvas ) = @_;
    $canvas->delete(TAG) if $canvas;
}

# ─── Dibujo interno ─────────────────────────────────────────────────────────

# Trend line: polilinea con TODOS los swings en orden cronologico.
sub _render_trendline {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_trendline');
    my $pts = $src->get_trendline or return;
    return if @$pts < 2;

    my $off  = $scale->{start_index} // 0;
    my $vb   = _visible_bars($scale);
    my $x_lo = $off - 5;
    my $x_hi = $off + $vb + 5;

    my @sorted = sort { $a->{index} <=> $b->{index} } @$pts;

    my @coords;
    for my $p (@sorted) {
        next if $p->{index} < $x_lo || $p->{index} > $x_hi;
        next unless _price_in_range( $scale, $p->{price} );
        push @coords,
            $scale->index_to_center_x( $p->{index} ),
            $scale->value_to_y( $p->{price} );
    }
    return if @coords < 4;

    $canvas->createLine( @coords,
        -fill   => C_TREND,
        -width  => 1,
        -smooth => 0,
        -tags   => [TAG],
    );
}

# Niveles BSL/SSL "resting": linea horizontal punteada + chip outline.
sub _render_levels {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $levels = $src->get_levels or return;

    my $off    = $scale->{start_index} // 0;
    my $vb     = _visible_bars($scale);
    my $plot_w = _plot_w($scale);
    my $x_lim  = $off + $vb;

    for my $kind ( 'buy', 'sell' ) {
        next if $kind eq 'buy'  && !$self->{show_bsl};
        next if $kind eq 'sell' && !$self->{show_ssl};

        my @resting = grep {
            $_->{side} eq $kind && $_->{state} ne 'RESOLVED' && $_->{state} ne 'EXPIRED'
        } @$levels;
        @resting = @resting[ -MAX_LINES .. -1 ] if @resting > MAX_LINES;

        my $color = ( $kind eq 'buy' ) ? C_BSL : C_SSL;
        my $text  = ( $kind eq 'buy' ) ? 'BSL' : 'SSL';

        for my $lv (@resting) {
            next if $lv->{index} > $x_lim;
            next unless _price_in_range( $scale, $lv->{price} );

            my $y  = $scale->value_to_y( $lv->{price} );
            my $x1 = $scale->index_to_center_x( $lv->{index} );
            $x1 = 0 if $x1 < 0;
            next if $x1 >= $plot_w;

            $canvas->createLine(
                $x1, $y, $plot_w, $y,
                -fill  => $color,
                -dash  => [ 2, 3 ],
                -width => 1,
                -tags  => [TAG],
            );

            $self->_chip( $canvas, $plot_w - 20, $y, $text,
                -color  => $color,
                -style  => 'outline',
                -place  => 'center',
                -placed => $placed,
            );
        }
    }
}

# Swing Points: marcador triangular (sin texto).
sub _render_swings {
    my ( $self, $canvas, $scale, $src ) = @_;
    my $swings = $src->get_swings or return;

    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);

    for my $sw (@$swings) {
        next if $sw->{index} < $off || $sw->{index} > $off + $vb;
        next unless _price_in_range( $scale, $sw->{price} );

        my $x     = $scale->index_to_center_x( $sw->{index} );
        my $up    = ( $sw->{kind} eq 'H' );
        my $y     = $scale->value_to_y( $sw->{price} );
        my $color = $up ? C_BSL : C_SSL;
        my $dy    = $up ? -7 : 7;

        $canvas->createLine( $x - 3, $y + $dy, $x, $y,
            -fill => $color, -width => 1, -tags => [TAG] );
        $canvas->createLine( $x + 3, $y + $dy, $x, $y,
            -fill => $color, -width => 1, -tags => [TAG] );
    }
}

# EQH / EQL: linea punteada que conecta ambos pivotes iguales + chip outline.
sub _render_equals {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $eqs = $src->get_equals or return;

    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);

    for my $e (@$eqs) {
        my $is_high = ( $e->{kind} eq 'EQH' );
        next if  $is_high && !$self->{show_eqh};
        next if !$is_high && !$self->{show_eql};

        next if $e->{i2} < $off || $e->{i1} > $off + $vb;
        next unless _price_in_range( $scale, $e->{p1} )
                 || _price_in_range( $scale, $e->{p2} );

        my $x1 = $scale->index_to_center_x( $e->{i1} );
        my $x2 = $scale->index_to_center_x( $e->{i2} );
        my $y1 = $scale->value_to_y( $e->{p1} );
        my $y2 = $scale->value_to_y( $e->{p2} );

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill  => C_EQ,
            -width => 1,
            -dash  => [ 4, 2 ],
            -tags  => [TAG],
        );

        $self->_chip( $canvas, ( $x1 + $x2 ) / 2, ( $y1 + $y2 ) / 2, $e->{kind},
            -color  => C_EQ,
            -style  => 'outline',
            -place  => ( $is_high ? 'above' : 'below' ),
            -placed => $placed,
        );
    }
}

# Eventos Sweep / Grab / Run.
sub _render_events {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $events = $src->get_events or return;

    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);

    my $start = $#$events - MAX_EVENTS;
    $start = 0 if $start < 0;

    for ( my $k = $#$events ; $k >= $start ; $k-- ) {
        my $ev = $events->[$k];
        my $t  = $ev->{type};
        next if $t eq 'SWEEP' && !$self->{show_sweeps};
        next if $t eq 'GRAB'  && !$self->{show_grabs};
        next if $t eq 'RUN'   && !$self->{show_runs};

        next if $ev->{index} < $off || $ev->{index} > $off + $vb;
        next unless _price_in_range( $scale, $ev->{price} );

        my $x = $scale->index_to_center_x( $ev->{index} );
        my $y = $scale->value_to_y( $ev->{price} );
        my $color =
            ( $t eq 'GRAB' ) ? C_GRAB
          : ( $t eq 'RUN' )  ? C_RUN
          : ( $ev->{dir} eq 'up' ) ? C_BSL : C_SSL;

        my $up = ( $ev->{dir} eq 'up' );
        my $dy = $up ? -10 : 10;

        $canvas->createLine( $x, $y, $x, $y + $dy,
            -fill  => $color,
            -width => 2,
            -tags  => [TAG],
        );
        $canvas->createOval( $x - 3, $y - 3, $x + 3, $y + 3,
            -fill    => $color,
            -outline => $color,
            -tags    => [TAG],
        );

        $self->_chip( $canvas, $x, $y + $dy, $ev->{label},
            -color  => $color,
            -style  => 'solid',
            -place  => ( $up ? 'above' : 'below' ),
            -placed => $placed,
        );
    }
}

# ─── _chip: etiqueta tipo TradingView ───────────────────────────────────────
#   -style 'solid'  : texto blanco sobre chip de color (eventos).
#   -style 'outline': texto de color sobre chip oscuro con borde de color.
#   -place 'above'|'below'|'center' respecto a (cx,cy).
#   Anti-solape: desplaza verticalmente si choca con etiqueta ya puesta.
sub _chip {
    my ( $self, $canvas, $cx, $cy, $text, %o ) = @_;
    my $color  = $o{-color}  // '#d6dbe6';
    my $style  = $o{-style}  // 'solid';
    my $place  = $o{-place}  // 'above';
    my $off    = defined $o{-offset} ? $o{-offset} : 9;
    my $font   = $o{-font}
              // ( $style eq 'solid' ? 'TkDefaultFont 12 bold' : 'TkDefaultFont 7 bold' );
    my $placed = $o{-placed};
    my $pad    = 2;

    my $ty = $place eq 'below'  ? $cy + $off
           : $place eq 'center' ? $cy
           :                      $cy - $off;

    my $tid = $canvas->createText(
        $cx, $ty,
        -text   => $text,
        -anchor => 'center',
        -font   => $font,
        -fill   => ( $style eq 'solid' ? '#ffffff' : $color ),
        -tags   => [TAG, TAG_LABELS],
    );
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

    my $fill = $style eq 'solid' ? $color : '#151a24';
    my $rid  = $canvas->createRectangle(
        $x1, $y1, $x2, $y2,
        -fill    => $fill,
        -outline => $color,
        -width   => 1,
        -stipple => 'gray50',
        -tags    => [TAG, TAG_LABELS],
    );
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

1;
