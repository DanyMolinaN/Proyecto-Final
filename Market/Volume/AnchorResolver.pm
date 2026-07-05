package Market::Volume::AnchorResolver;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        market_data      => $args{market_data},
        structure_engine => $args{structure_engine},
        concept_engines  => $args{concept_engines} || {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub resolve_anchor {
    my ($self, $anchor) = @_;
    return unless $anchor && ref $anchor eq 'HASH';

    my $type = $anchor->{type};
    return unless $type;

    if ($type eq 'manual_index') {
        return $anchor->{index} if defined $anchor->{index};
    }
    if ($type eq 'timestamp') {
        return $self->_resolve_by_timestamp($anchor->{timestamp});
    }
    if ($type eq 'session_open') {
        return $self->_resolve_session_open($anchor->{session_open_index});
    }
    if ($type eq 'bos') {
        return $self->_resolve_break_of_structure($anchor);
    }
    if ($type eq 'choch') {
        return $self->_resolve_choch($anchor);
    }
    if ($type eq 'fvg_creation') {
        return $self->_resolve_fvg_creation($anchor);
    }
    if ($type eq 'orderblock_creation') {
        return $self->_resolve_orderblock_creation($anchor);
    }
    if ($type eq 'liquidity_sweep') {
        return $self->_resolve_liquidity_sweep($anchor);
    }

    return;
}

sub _structure_data {
    my ($self) = @_;
    my $eng = $self->_engine('structure');
    return unless $eng && $eng->can('structure');
    return $eng->structure();
}

sub _engine {
    my ($self, $name) = @_;
    my $ce = $self->{concept_engines} || {};
    return $ce->{$name} if $ce->{$name};

    if ($name eq 'structure') {
        return $self->{structure_engine};
    }
    if ($name eq 'orderblock' || $name eq 'order_block') {
        return $ce->{orderblock} || $ce->{order_block};
    }
    return;
}

sub _resolve_by_timestamp {
    my ($self, $timestamp) = @_;
    return unless defined $timestamp;

    my $md = $self->{market_data};
    return unless $md;

    for my $index (0 .. $md->size() - 1) {
        my $c = $md->get_candle($index);
        next unless $c && defined $c->{timestamp};
        return $index if $c->{timestamp} == $timestamp;
    }
    return;
}

sub _resolve_session_open {
    my ($self, $session_open_index) = @_;
    return $session_open_index if defined $session_open_index;
    return;
}

sub _resolve_break_of_structure {
    my ($self, $anchor) = @_;
    my $structure = $self->_structure_data();
    return unless $structure && ref $structure->{breaks} eq 'ARRAY';

    my $direction = $anchor->{direction};
    for my $break (@{ $structure->{breaks} }) {
        next unless defined $break->{confirmation_index} || defined $break->{index};
        my $idx = $break->{confirmation_index} // $break->{index};
        next if defined $direction && ($break->{direction} || '') ne $direction;
        return $idx;
    }
    return;
}

sub _resolve_choch {
    my ($self, $anchor) = @_;
    my $structure = $self->_structure_data();
    return unless $structure && ref $structure->{changes} eq 'ARRAY';

    my $direction = $anchor->{direction};
    for my $change (@{ $structure->{changes} }) {
        next unless defined $change->{index};
        next if defined $direction && ($change->{direction} || '') ne $direction;
        return $change->{index};
    }
    return;
}

sub _resolve_fvg_creation {
    my ($self, $anchor) = @_;
    my $fvg = $self->_engine('fvg');
    return unless $fvg && $fvg->can('calculate');

    my $result = $fvg->calculate($self->{market_data}, $self->{structure_engine});
    return unless $result && ref $result->{gaps} eq 'ARRAY';

    my $direction = $anchor->{direction};
    for my $gap (@{ $result->{gaps} }) {
        next unless defined $gap->{created_index};
        next if defined $direction && ($gap->{type} || '') !~ /$direction/i;
        return $gap->{created_index};
    }
    return;
}

sub _resolve_orderblock_creation {
    my ($self, $anchor) = @_;
    my $ob = $self->_engine('orderblock') || $self->_engine('order_block');
    return unless $ob && $ob->can('calculate');

    my $result = $ob->calculate($self->{market_data}, $self->{structure_engine});
    return unless $result && ref $result->{blocks} eq 'ARRAY';

    my $direction = $anchor->{direction};
    for my $block (@{ $result->{blocks} }) {
        next unless defined $block->{origin_index};
        next if defined $direction && ($block->{type} || '') ne $direction;
        return $block->{origin_index};
    }
    return;
}

sub _resolve_liquidity_sweep {
    my ($self, $anchor) = @_;
    my $liq = $self->_engine('liquidity');
    return unless $liq && $liq->can('calculate');

    my $liquidity = $liq->calculate($self->{market_data});
    return unless $liquidity;

    my $events = $liquidity->{events} || $liquidity->{sweeps} || [];
    return unless ref $events eq 'ARRAY';

    for my $sweep (@$events) {
        next unless ($sweep->{type} || '') =~ /Sweep/i;
        my $idx = $sweep->{end} // $sweep->{index};
        return $idx if defined $idx;
    }
    return;
}

1;
