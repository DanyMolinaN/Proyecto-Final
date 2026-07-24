package Market::Overlays::AnchoredVWAPOverlay;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data     => undef,
        canvas   => $args{canvas},
        scale    => $args{scale},
        elements => [],
        %args,
    };
    bless $self, $class;
    return $self;
}

sub set_data {
    my ($self, $data) = @_;
    $self->{data} = $data;
    return $self;
}

use constant TAG        => 'overlay_anchored_vwap';
use constant TAG_LABELS => 'overlay_anchored_vwap_labels';

use constant {
    C_VWAP     => '#2962ff',
    C_ANCHOR   => '#4f8cff',
    C_BAND1    => '#2962ff',
    C_BAND2    => '#5b8def',
    C_BAND3    => '#8fb3f5',

    # Preview Ghost Colors
    C_GHOST_VWAP  => '#78909c',
    C_GHOST_BAND1 => '#90a4ae',
    C_GHOST_BAND2 => '#b0bec5',
    C_GHOST_BAND3 => '#cfd8dc',
    VWAP_WIDTH => 2,
};

sub draw {
    my ($self, %args) = @_;
    my $canvas = $args{canvas} || $self->{canvas};
    my $scale  = $args{scale}  || $self->{scale};
    my $data   = $args{data}   || $self->{data};
    return unless $canvas && $scale && $data && ref($data) eq 'HASH';

    my $settings = $args{settings} || $self->{settings};
    if ($settings && $settings->can('enabled')) {
        return $self unless $settings->enabled('show_anchored_vwap');
    }

    $self->clear($canvas);

    my $points = $data->{points};
    return $self unless $points && @$points;

    my $start_idx = $scale->{start_index} // 0;
    my $vb        = $scale->{width} / ($scale->{candle_width} || 8);
    my $end_idx   = $start_idx + $vb;

    my $anchor_idx   = $data->{anchor_index};
    my $anchor_price = $data->{anchor_price};

    if ( defined $anchor_idx ) {
        my $ax = $scale->index_to_center_x($anchor_idx);
        my $plot_w = $scale->{width} || 1000;
        if ( $ax >= 0 && $ax <= $plot_w ) {
            $canvas->createLine(
                $ax, 0, $ax, $scale->{price_height} || 800,
                -fill => C_ANCHOR, -width => 1, -dash => [ 3, 3 ],
                -tags => [TAG],
            );
            if ( defined $anchor_price ) {
                my $ay = $scale->value_to_y($anchor_price);
                my $r  = 6;
                $canvas->createOval(
                    $ax - $r, $ay - $r, $ax + $r, $ay + $r,
                    -fill => C_ANCHOR, -outline => '#ffffff', -width => 2,
                    -tags => [TAG],
                );
            }
            $canvas->createText(
                $ax + 4, 10,
                -text => 'AVWAP', -anchor => 'w', -fill => C_ANCHOR,
                -font => 'TkDefaultFont 7 bold', -tags => [ TAG, TAG_LABELS ],
            );
        }
    }

    my @visible = grep { $_->{index} >= $start_idx - 1 && $_->{index} <= $end_idx + 1 } @$points;
    return $self unless @visible;

    my $anchor_kind = $data->{anchor_kind} // 'regular';
    my $dash_style  = undef;
    if ($anchor_kind eq 'ghost') {
        my $show_ghost = $settings && $settings->can('enabled') ? $settings->enabled('show_ghost_pivots') // 1 : 1;
        if ($show_ghost) {
            $dash_style = [4, 4];
        }
    }

    # Bands
    $self->_draw_band( $canvas, $scale, \@visible, 'upper1', 'lower1', C_BAND1, 1, $dash_style );
    $self->_draw_band( $canvas, $scale, \@visible, 'upper2', 'lower2', C_BAND2, 1, $dash_style );
    $self->_draw_band( $canvas, $scale, \@visible, 'upper3', 'lower3', C_BAND3, 1, $dash_style );

    # Center line
    $self->_draw_line( $canvas, $scale, \@visible, 'vwap', C_VWAP, VWAP_WIDTH, $dash_style );

    my $last_pt = $visible[-1];
    if ( defined $last_pt->{vwap} ) {
        my $lx = $scale->index_to_center_x( $last_pt->{index} );
        my $ly = $scale->value_to_y( $last_pt->{vwap} );
        $canvas->createText(
            $lx + 4, $ly,
            -text => sprintf( '%.4f', $last_pt->{vwap} ),
            -anchor => 'w', -fill => C_VWAP,
            -font => 'TkDefaultFont 7 bold', -tags => [ TAG, TAG_LABELS ],
        );
    }

    # Live Ghost Preview (only if it reaches the viewport)
    if (my $preview = $data->{live_preview}) {
        my $preview_end = $preview->{to_index};
        if ($preview_end >= $start_idx && $preview_end <= $end_idx + 1) {
            my $p_points = $preview->{points};
            if ($p_points && @$p_points) {
                my @p_vis = grep { $_->{index} >= $start_idx - 1 && $_->{index} <= $end_idx + 1 } @$p_points;
                if (@p_vis) {
                    $self->_draw_band( $canvas, $scale, \@p_vis, 'upper1', 'lower1', C_GHOST_BAND1, 1, [2,2] );
                    $self->_draw_band( $canvas, $scale, \@p_vis, 'upper2', 'lower2', C_GHOST_BAND2, 1, [2,2] );
                    $self->_draw_band( $canvas, $scale, \@p_vis, 'upper3', 'lower3', C_GHOST_BAND3, 1, [2,2] );
                    $self->_draw_line( $canvas, $scale, \@p_vis, 'vwap', C_GHOST_VWAP, VWAP_WIDTH, [2,2] );
                }
            }
        }
    }

    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    return unless $canvas && $canvas->can('delete');
    $canvas->delete(TAG);
    $canvas->delete(TAG_LABELS);
    $self->{elements} = [];
    return $self;
}

sub _draw_line {
    my ( $self, $canvas, $scale, $points, $field, $color, $width, $dash ) = @_;
    my @coords;
    for my $p (@$points) {
        next unless defined $p->{$field};
        push @coords, $scale->index_to_center_x( $p->{index} ), $scale->value_to_y( $p->{$field} );
    }
    return if @coords < 4;
    my @args = ( -fill => $color, -width => $width, -tags => [TAG] );
    push @args, ( -dash => $dash ) if $dash;
    $canvas->createLine( @coords, @args );
}

sub _draw_band {
    my ( $self, $canvas, $scale, $points, $upper_field, $lower_field, $color, $width, $dash ) = @_;
    $self->_draw_line( $canvas, $scale, $points, $upper_field, $color, $width, $dash );
    $self->_draw_line( $canvas, $scale, $points, $lower_field, $color, $width, $dash );
}

1;
