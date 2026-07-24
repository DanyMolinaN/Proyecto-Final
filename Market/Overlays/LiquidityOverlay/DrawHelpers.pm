package Market::Overlays::LiquidityOverlay;

# =============================================================================
# LiquidityOverlay::DrawHelpers
# =============================================================================
# Tags, clip y helpers visuales de liquidez.
# Continuacion de Market::Overlays::LiquidityOverlay (SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _draw_tag {
    my ($canvas, $item, $style) = @_;
    return unless $canvas && $item;
    $style ||= {};
    my $text = $item->{text};
    return unless defined $text;

    my $pad_x = $style->{pad_x} || 3;
    my $pad_y = $style->{pad_y} || 1;
    my $text_w = length($text) * ($style->{text_w} || 5);
    my $h = ($style->{text_h} || 10) + $pad_y * 2;
    my $x = $item->{x_base};
    my $y = $item->{y_base};
    my $anchor = $item->{anchor} || 'c';

    my ($left, $right);
    if ($anchor eq 'w') {
        $left  = $x - $pad_x;
        $right = $x + $text_w + $pad_x;
    }
    elsif ($anchor eq 'e') {
        $left  = $x - $text_w - $pad_x;
        $right = $x + $pad_x;
    }
    else {
        $left  = $x - $text_w / 2 - $pad_x;
        $right = $x + $text_w / 2 + $pad_x;
    }

    my $text_anchor = ($anchor eq 'w' || $anchor eq 'e') ? $anchor : 'c';

    $canvas->createRectangle(
        $left, $y - $h / 2, $right, $y + $h / 2,
        -fill => $item->{bg} || $style->{bg} || '#14191d',
        -outline => $item->{fill},
        -width => 1,
        -tags => ['overlay_liquidity_dynamic'],
    );
    $canvas->createText($x, $y,
        -text   => $text,
        -anchor => $text_anchor,
        -fill   => $item->{fill},
        -font   => $item->{font} || $style->{font} || 'Helvetica 7',
        -tags   => ['overlay_liquidity_dynamic'],
    );
}

sub _y_in_clip {
    my ($y, $top, $bottom) = @_;
    return 1 unless defined $y;
    return 0 if defined $top    && $y < $top - 4;
    return 0 if defined $bottom && $y > $bottom + 2;
    return 1;
}

sub _liquidity_color {
    my ($type) = @_;
    return '#e53935' if defined $type && $type eq 'BSL';   # Rojo (spec)
    return '#43a047' if defined $type && $type eq 'SSL';   # Verde (spec)
    return '#9c27b0' if defined $type && $type eq 'EQH';
    return '#7b1fa2' if defined $type && $type eq 'EQL';
    return '#4dd0e1';
}

sub _liquidity_visual {
    my ($level) = @_;
    my $type = $level->{type};
    my $state = lc($level->{state} // $level->{status} // 'detected');
    my $fill = _liquidity_color($type);
    my $width = 1;
    my $dash = [4, 3];

    if ($state eq 'candidate') {
        $fill = '#5f6872';
        $dash = [2, 4];
    }
    elsif ($state eq 'swept') {
        $width = 2;
        $dash = undef;
    }
    elsif ($state eq 'acceptance') {
        $width = 3;
        $dash = undef;
    }
    elsif ($state eq 'reclaimed') {
        $fill = '#7d8991';
        $dash = [5, 5];
    }
    elsif ($state eq 'run') {
        $fill = '#42a5f5';
        $width = 3;
        $dash = undef;
    }
    elsif ($state eq 'resolved') {
        $fill = '#4b535b';
        $dash = [1, 5];
    }

    return ($fill, $width, $dash);
}

sub _level_id {
    my ($level, $idx, $price) = @_;
    return $level->{id} if defined $level->{id} && $level->{id} ne '';
    return join(':',
        'liq',
        $level->{scope} // 'external',
        $level->{type}  // 'LEV',
        defined $idx ? $idx : 'na',
        defined $price ? sprintf('%.5f', $price) : 'na',
    );
}

sub _upsert_level_line {
    my ($self, $canvas, $id, $x1, $y, $x2, $fill, $width, $dash) = @_;
    return unless $canvas && defined $id;
    my $cache = $self->{object_cache} ||= {};
    my $item_id = $cache->{$id};
    my @tags = ('overlay_liquidity', 'overlay_liquidity_level', "liq_level_$id");

    if ($item_id && $canvas->can('coords') && $canvas->can('itemconfigure')) {
        eval {
            $canvas->coords($item_id, $x1, $y, $x2, $y);
            $canvas->itemconfigure($item_id,
                -fill => $fill,
                -width => $width,
                -dash => ($dash || ''),
                -state => 'normal',
            );
            1;
        } and return;
    }

    $item_id = $canvas->createLine($x1, $y, $x2, $y,
        -fill => $fill,
        -width => $width,
        -dash => ($dash || undef),
        -tags => \@tags,
    );
    $cache->{$id} = $item_id if defined $item_id;
}

sub _hide_stale_level_lines {
    my ($self, $canvas, $visible) = @_;
    return unless $self && $canvas;
    my $cache = $self->{object_cache} || {};
    for my $id (keys %$cache) {
        next if $visible && $visible->{$id};
        my $item_id = $cache->{$id};
        if ($canvas->can('itemconfigure')) {
            eval { $canvas->itemconfigure($item_id, -state => 'hidden'); 1; };
        }
    }
}

sub _liquidity_y_offset {
    my ($type) = @_;
    return -18 if defined $type && $type eq 'BSL';
    return  18 if defined $type && $type eq 'SSL';
    return 0;
}

sub _eq_color {
    my ($type) = @_;
    return '#42a5f5' if defined $type && $type eq 'EQH'; # Blue/celeste
    return '#ef5350' if defined $type && $type eq 'EQL'; # Red
    return '#42a5f5';
}

sub _event_y_offset {
    my ($type) = @_;
    return -10 if defined $type && $type eq 'Run';
    return -22 if defined $type && $type eq 'Sweep';
    return  10 if defined $type && $type eq 'Grab';
    return -8;
}

sub _event_label {
    my ($event) = @_;
    if (defined $event->{type} && $event->{type} eq 'Sweep') {
        return 'SWEEP';
    }
    return 'LQ RUN'  if defined $event->{type} && $event->{type} eq 'Run';
    return 'LQ GRAB' if defined $event->{type} && $event->{type} eq 'Grab';
    return defined $event->{type} ? uc($event->{type}) : 'EVENT';
}

sub _event_color {
    my ($event) = @_;
    if (defined $event->{type} && $event->{type} eq 'Sweep') {
        return ($event->{direction} // '') eq 'down' ? '#43a047' : '#e53935';
    }
    return '#42a5f5' if defined $event->{type} && $event->{type} eq 'Run';   # Azul
    return '#ff9800' if defined $event->{type} && $event->{type} eq 'Grab';  # Naranja
    return '#ff9800';
}

sub _event_price {
    my ($event, $market_data) = @_;
    return $event->{price} if defined $event->{price};
    return $event->{level} if defined $event->{level};
    return $event->{value} if defined $event->{value};
    return undef unless $market_data && $market_data->can('get_candle');

    my $idx = defined $event->{end} ? $event->{end} : $event->{start};
    return undef unless defined $idx;
    my $candle = $market_data->get_candle($idx);
    return undef unless $candle && ref($candle) eq 'HASH';
    return $candle->{close} if defined $candle->{close};
    return $candle->{high} if defined $candle->{high};
    return $candle->{low} if defined $candle->{low};
    return undef;
}


1;
