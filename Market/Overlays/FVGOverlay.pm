package Market::Overlays::FVGOverlay;

# =============================================================================
# Market::Overlays::FVGOverlay
#
# Dibuja Fair Value Gaps segun la logica de Proyecto_David (SMC_Structures2):
#   - state 'active'    → color vivo (bull teal / bear red)
#   - state 'mitigated' → gris (mitigacion parcial; sigue vivo)
#   - state 'deleted' / filled=1 → no se dibuja
#
# Sin fade por edad (max_age): solo se ocultan los borrados totalmente.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data     => undef,
        canvas   => $args{canvas},
        scale    => $args{scale},
        settings => $args{settings},
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

sub draw {
    my ($self, %args) = @_;
    my $canvas    = $args{canvas} || $self->{canvas};
    my $scale     = $args{scale}  || $self->{scale};
    my $data      = $args{data}   || $self->{data};
    my $start_idx = $args{start_idx};
    my $end_idx   = $args{end_idx};
    my $clip_y_top    = $args{clip_y_top};
    my $clip_y_bottom = $args{clip_y_bottom};
    return unless $canvas && $scale;
    return unless $data;

    $self->clear($canvas);
    return $self if $self->{settings}
        && $self->{settings}->can('enabled')
        && !$self->{settings}->enabled('show_fvg');

    # Preferir active (vivos); si no hay, filtrar gaps no-deleted
    my $gaps = $data->{active};
    if (!$gaps || ref($gaps) ne 'ARRAY' || !@$gaps) {
        $gaps = [ grep {
            $_ && ref $_ eq 'HASH'
            && !$_->{filled}
            && ($_->{state} // 'active') ne 'deleted'
        } @{ $data->{gaps} || [] } ];
    }
    return $self unless ref($gaps) eq 'ARRAY';

    my $total_received = scalar(@$gaps);
    my $discarded_invalid = 0;
    my $discarded_viewport = 0;
    my $rendered = 0;
    my $max_render = 60;

    my @draw_gaps = grep {
        my $g = $_;
        $g && ref($g) eq 'HASH'
            && !($g->{filled})
            && (($g->{state} // 'active') ne 'deleted')
    } @$gaps;

    @draw_gaps = sort {
        ($b->{created_index} // $b->{index} // 0)
            <=> ($a->{created_index} // $a->{index} // 0)
    } @draw_gaps;

    my $cw = $scale->index_to_center_x(1) - $scale->index_to_center_x(0);
    my $half = $cw > 0 ? $cw / 2 : 2;

    for my $gap (@draw_gaps) {
        my $ci   = $gap->{created_index} // $gap->{index} // $gap->{idx_start};
        my $ei   = $gap->{extend_to}     // (defined $end_idx ? $end_idx : $ci);
        my $type = $gap->{type} // (($gap->{dir} // '') eq 'bear' ? 'bearish' : 'bullish');
        my $top    = $gap->{top};
        my $bottom = $gap->{bottom};
        unless (defined $ci && defined $type && defined $top && defined $bottom) {
            $discarded_invalid++;
            next;
        }

        if (defined $end_idx && $ci > $end_idx)   { $discarded_viewport++; next; }
        if (defined $start_idx && $ei < $start_idx) { $discarded_viewport++; next; }

        my $state = $gap->{state} // 'active';
        my $is_mitigated = ($state eq 'mitigated');

        # Colores: activo = teal/rojo; mitigado parcial = gris (como David)
        my ($fill, $stip);
        if ($is_mitigated) {
            $fill = '#6b7280';
            $stip = 'gray25';
        }
        else {
            my $base = $type eq 'bearish' ? [0xef, 0x53, 0x50] : [0x26, 0xa6, 0x9a];
            $fill = sprintf('#%02x%02x%02x', @$base);
            $stip = 'gray50';
        }

        my $x1 = $scale->index_to_center_x($ci) - $half;
        my $draw_end = $ei;
        $draw_end = $end_idx if defined $end_idx && $draw_end > $end_idx;
        my $x2 = $scale->index_to_center_x($draw_end) + $half;
        $x2 = $x1 + ($half * 2) if $x2 <= $x1;

        my $y1 = $scale->value_to_y($top);
        my $y2 = $scale->value_to_y($bottom);
        ($y1, $y2) = ($y2, $y1) if $y1 > $y2;
        next if defined $clip_y_bottom && $y1 > $clip_y_bottom;
        $y2 = $clip_y_bottom if defined $clip_y_bottom && $y2 > $clip_y_bottom;
        next if $y2 <= $y1;

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $fill,
            -stipple => $stip,
            -outline => $fill,
            -width   => 1,
            -tags    => ['overlay_fvg'],
        );

        my $label = $type eq 'bullish' ? 'FVG+' : 'FVG-';
        $label .= ' m' if $is_mitigated;
        my $lx = $scale->index_to_center_x($ci) + 2;
        my $ly = ($y1 + $y2) / 2;
        $canvas->createText($lx, $ly,
            -text   => $label,
            -anchor => 'w',
            -fill   => $fill,
            -font   => 'Helvetica 7 bold',
            -tags   => ['overlay_fvg'],
        );

        $rendered++;
        last if $rendered >= $max_render;
    }

    $self->{smc_audit} = {
        total_received        => $total_received,
        discarded_by_viewport => $discarded_viewport,
        discarded_invalid     => $discarded_invalid,
        rendered              => $rendered,
    };

    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_fvg') if $canvas && $canvas->can('delete');
    $self->{elements} = [];
    return $self;
}

1;
