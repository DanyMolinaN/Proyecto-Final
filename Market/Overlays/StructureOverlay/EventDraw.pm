package Market::Overlays::StructureOverlay;

# =============================================================================
# StructureOverlay::EventDraw
# =============================================================================
# Anclas, spans y leaders de eventos BOS/CHoCH/EQ.
# Continuacion del paquete Market::Overlays::StructureOverlay (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _event_anchor_y {
    my ($point, $level, $idx, $market_data, $scale) = @_;
    if ($market_data && $market_data->can('get_candle') && defined $idx) {
        my $c = $market_data->get_candle($idx);
        if ($c && ref($c) eq 'HASH' && defined $c->{close}) {
            return $scale->value_to_y($c->{close});
        }
    }
    return $scale->value_to_y($level) if defined $level;
    return undef;
}

sub _event_span {
    my ($point, $scale, $level, $idx, $fallback_y) = @_;
    return (undef, undef, undef) unless $point && $scale;

    my $origin_idx = defined $point->{break_index} ? $point->{break_index}
                   : defined $point->{swing_index} ? $point->{swing_index}
                   : undef;
    return (undef, undef, undef) unless defined $origin_idx && defined $idx;

    my $x1 = $scale->index_to_center_x($origin_idx);
    my $x2 = $scale->index_to_center_x($idx);
    ($x1, $x2) = ($x2, $x1) if $x2 < $x1;
    $x2 = $x1 + 1 if $x2 <= $x1;

    my $y = defined $level ? $scale->value_to_y($level) : $fallback_y;
    return (undef, undef, undef) unless defined $y;
    return ($x1, $x2, $y);
}

sub _draw_event_span {
    my ($canvas, $item, $style) = @_;
    return unless $canvas && $item && $item->{span};
    my $span = $item->{span};
    return unless defined $span->{x1} && defined $span->{x2} && defined $span->{y};
    my $fg = $item->{fg} || '#d8dee9';

    my @line_args = (
        $span->{x1}, $span->{y}, $span->{x2}, $span->{y},
        -fill  => $fg,
        -width => 1,
        -tags  => ['overlay_structure'],
    );
    push @line_args, (-dash => $span->{dash}) if defined $span->{dash};
    $canvas->createLine(@line_args);

    if (defined $span->{break_x}) {
        $canvas->createLine($span->{break_x}, $span->{y} - 4, $span->{break_x}, $span->{y} + 4,
            -fill  => $fg,
            -width => 1,
            -tags  => ['overlay_structure'],
        );
    }
}

sub _draw_leader {
    my ($canvas, $x1, $y1, $x2, $y2, $fg) = @_;
    return unless $canvas && defined $x1 && defined $y1 && defined $x2 && defined $y2;
    return if abs($x1 - $x2) < 1 && abs($y1 - $y2) < 1;
    $canvas->createLine($x1, $y1, $x2, $y2,
        -fill => $fg, -width => 1, -dash => [2, 2],
        -tags => ['overlay_structure'],
    );
}


1;
