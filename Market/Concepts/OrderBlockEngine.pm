package Market::Concepts::OrderBlockEngine;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        blocks => [],
        active => [],
        metadata => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{blocks} = [];
    $self->{active} = [];
    $self->{metadata} = {};
    return $self;
}

sub calculate {
    my ($self, $market_data, $structure_engine, %args) = @_;
    return {} unless $market_data;

    $self->reset();
    my $candles = [];
    my $total = $market_data->size();
    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit : ($total - 1);

    for (my $i = 0; $i <= $last_index; $i++) {
        my $c = $market_data->get_candle($i);
        push @$candles, $c if $c;
    }

    my $structure = $structure_engine ? $structure_engine->structure() : {};
    my $breaks = $structure->{breaks} || [];
    my $blocks = [];

    for my $break (@$breaks) {
        next if defined $visible_limit && ($break->{confirmation_index} // $break->{index}) > $visible_limit;
        my $index = $break->{break_index} // $break->{swing_index};
        next unless defined $index;
        my $origin_index = $index - 1;
        my $origin = $candles->[$origin_index];
        next unless $origin;

        my $type = ($break->{direction} || '') eq 'bullish' ? 'bullish' : 'bearish';
        my $block_price = $type eq 'bullish' ? $origin->{high} : $origin->{low};
        my $conf = $break->{confirmation_index} // $break->{index};
        push @$blocks, {
            type                 => $type,
            high                 => $origin->{high},
            low                  => $origin->{low},
            price                => $block_price,
            value                => $block_price,
            index                => $origin_index,
            created_index        => $origin_index,
            origin_index         => $origin_index,
            confirmation_index   => $conf,
            state                => 'Detected',
            invalidated_index    => undef,
        };
    }

    $self->_apply_invalidation($blocks, $candles, $last_index);

    $self->{blocks} = $blocks;
    $self->{active} = [ grep { ($_->{state} || '') ne 'Invalidated' } @$blocks ];
    $self->{metadata} = {
        timeframe       => $args{timeframe} || $market_data->active_tf(),
        block_count     => scalar(@$blocks),
        active_count    => scalar(@{ $self->{active} }),
        visible_limit   => $visible_limit,
    };

    return {
        blocks   => $self->{blocks},
        active   => $self->{active},
        metadata => $self->{metadata},
    };
}

sub _apply_invalidation {
    my ($self, $blocks, $candles, $last_index) = @_;
    return unless $blocks && $candles && defined $last_index;

    for my $block (@$blocks) {
        my $start = $block->{confirmation_index};
        next unless defined $start;
        for (my $i = $start + 1; $i <= $last_index && $i < @$candles; $i++) {
            my $c = $candles->[$i];
            next unless $c;
            if ($block->{type} eq 'bullish' && $c->{close} < $block->{low}) {
                $block->{state}             = 'Invalidated';
                $block->{invalidated_index} = $i;
                last;
            }
            if ($block->{type} eq 'bearish' && $c->{close} > $block->{high}) {
                $block->{state}             = 'Invalidated';
                $block->{invalidated_index} = $i;
                last;
            }
        }
    }
}

sub blocks { my ($self) = @_; return $self->{blocks} || []; }
sub active { my ($self) = @_; return $self->{active} || []; }

1;
