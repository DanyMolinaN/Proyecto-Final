#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Market::Overlays::StructureOverlay;
use Market::Overlays::LiquidityOverlay;

{
    package _Canvas;
    sub new { bless { items => [] }, shift }
    sub createLine { my ($s, @args) = @_; push @{ $s->{items} }, ['line', @args]; return scalar @{ $s->{items} }; }
    sub createRectangle { my ($s, @args) = @_; push @{ $s->{items} }, ['rect', @args]; return scalar @{ $s->{items} }; }
    sub createText { my ($s, @args) = @_; push @{ $s->{items} }, ['text', @args]; return scalar @{ $s->{items} }; }
    sub delete {
        my ($s, @tags) = @_;
        return $s->{items} = [] unless @tags;
        my %tag = map { $_ => 1 } @tags;
        $s->{items} = [
            grep {
                my $it = $_;
                my $keep = 1;
                for (my $i = 1; $i < @$it; $i++) {
                    next unless defined $it->[$i] && $it->[$i] eq '-tags';
                    my $tags = $it->[$i + 1];
                    my @item_tags = ref($tags) eq 'ARRAY' ? @$tags : ($tags);
                    $keep = 0 if grep { $tag{$_} } @item_tags;
                }
                $keep;
            } @{ $s->{items} }
        ];
        return 1;
    }
    sub can { my ($s, $m) = @_; return $s->SUPER::can($m); }
}

{
    package _Scale;
    sub new { bless { candle_width => 10, width => 900, y_axis_strip_w => 66 }, shift }
    sub index_to_center_x { my ($s, $i) = @_; return 20 + $i * 10; }
    sub index_to_x { my ($s, $i) = @_; return 15 + $i * 10; }
    sub value_to_y { my ($s, $v) = @_; return 500 - $v; }
}

sub texts {
    my ($canvas) = @_;
    return grep { $_->[0] eq 'text' } @{ $canvas->{items} };
}

sub lines {
    my ($canvas) = @_;
    return grep { $_->[0] eq 'line' } @{ $canvas->{items} };
}

sub text_by_label {
    my ($canvas, $re) = @_;
    for my $item (texts($canvas)) {
        for (my $i = 1; $i < @$item; $i++) {
            next unless defined $item->[$i] && $item->[$i] eq '-text';
            return $item if ($item->[$i + 1] // '') =~ $re;
        }
    }
    return undef;
}

sub assert {
    my ($cond, $msg) = @_;
    die "$msg\n" unless $cond;
}

my $scale = _Scale->new;

# BOS/CHoCH render contract:
# - x1 = broken swing candle center
# - x2 = break/confirmation candle center
# - y  = broken level
# - label center = midpoint of the same horizontal line
{
    my $canvas = _Canvas->new;
    my $overlay = Market::Overlays::StructureOverlay->new(canvas => $canvas, scale => $scale);
    my $data = {
        external_swings => [],
        breaks => [
            { type => 'BOS', direction => 'bullish', break_index => 3, index => 9, level => 120 },
        ],
        changes => [
            { type => 'CHoCH', direction => 'bearish', break_index => 12, index => 16, level => 98 },
        ],
    };
    $overlay->draw(canvas => $canvas, scale => $scale, data => $data, start_idx => 0, end_idx => 30);

    my ($bos_x1, $bos_x2, $bos_y) = (50, 110, 380);
    my ($choch_x1, $choch_x2, $choch_y) = (140, 180, 402);

    assert(
        scalar(grep { $_->[1] == $bos_x1 && $_->[2] == $bos_y && $_->[3] == $bos_x2 && $_->[4] == $bos_y } lines($canvas)),
        'BOS line does not match broken swing -> break candle at broken level'
    );
    assert(
        scalar(grep { $_->[1] == $choch_x1 && $_->[2] == $choch_y && $_->[3] == $choch_x2 && $_->[4] == $choch_y } lines($canvas)),
        'CHoCH line does not match broken swing -> break candle at broken level'
    );

    my $bos_text = text_by_label($canvas, qr/^BOS/);
    my $choch_text = text_by_label($canvas, qr/^CHoCH/);
    assert($bos_text && $bos_text->[1] == (($bos_x1 + $bos_x2) / 2) && $bos_text->[2] == $bos_y,
        'BOS label is not exactly centered on its horizontal line');
    assert($choch_text && $choch_text->[1] == (($choch_x1 + $choch_x2) / 2) && $choch_text->[2] == $choch_y,
        'CHoCH label is not exactly centered on its horizontal line');
}

# Liquidity render contract:
# - BSL/SSL semirrecta starts at liquidity origin
# - label anchors to the right end of the line, not the origin
{
    my $canvas = _Canvas->new;
    my $overlay = Market::Overlays::LiquidityOverlay->new(canvas => $canvas, scale => $scale);
    my $data = {
        liquidity_levels => [
            { id => 'bsl-a', created_index => 2, price => 130, type => 'BSL', scope => 'external' },
            { id => 'ssl-a', created_index => 4, price => 90,  type => 'SSL', scope => 'external' },
        ],
        eq_levels => [
            { first_index => 5, second_index => 8, level => 125, type => 'EQH' },
        ],
        events => [],
    };
    $overlay->draw(canvas => $canvas, scale => $scale, data => $data, start_idx => 0, end_idx => 20);

    my $x_end = $scale->index_to_x(20);
    my $bsl_text = text_by_label($canvas, qr/^BSL$/);
    my $ssl_text = text_by_label($canvas, qr/^SSL$/);
    my $eqh_text = text_by_label($canvas, qr/^EQH$/);

    assert($bsl_text && $bsl_text->[1] == $x_end - 4, 'BSL label is not anchored to the right end');
    assert($ssl_text && $ssl_text->[1] == $x_end - 4, 'SSL label is not anchored to the right end');
    assert($eqh_text && $eqh_text->[1] == (($scale->index_to_x(5) + $scale->index_to_x(8)) / 2),
        'EQH label is not centered on its EQH line');
}

print "OK render contract verification\n";
exit 0;
