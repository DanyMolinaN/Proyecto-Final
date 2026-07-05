package Market::Core::OverlayManager;

# =============================================================================
# Market::Core::OverlayManager
# =============================================================================
# Gestor de overlays: registro, orden de dibujo, enable/disable por capa.
# =============================================================================

use strict;
use warnings;

=head1 NAME

Market::Core::OverlayManager - gestor base de overlays.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        initialized => 0,
        overlays    => {},
        order       => [],
        %args,
    };
    bless $self, $class;
    return $self;
}

sub initialize {
    my ($self) = @_;
    $self->{initialized} = 1;
    return $self;
}

sub register {
    my ($self, $name, $overlay) = @_;
    return 0 unless defined $name && defined $overlay;
    $self->{overlays}->{$name} = $overlay;
    push @{ $self->{order} }, $name unless grep { $_ eq $name } @{ $self->{order} || [] };
    return 1;
}

sub enable {
    my ($self, $name) = @_;
    return 0 unless defined $name && exists $self->{overlays}->{$name};
    my $overlay = $self->{overlays}->{$name};
    $overlay->{enabled} = 1 if ref($overlay) && ref($overlay) eq 'HASH';
    $overlay->{enabled} = 1 if ref($overlay) && ref($overlay) ne 'HASH';
    return 1;
}

sub disable {
    my ($self, $name) = @_;
    return 0 unless defined $name && exists $self->{overlays}->{$name};
    my $overlay = $self->{overlays}->{$name};
    $overlay->{enabled} = 0 if ref($overlay) && ref($overlay) eq 'HASH';
    $overlay->{enabled} = 0 if ref($overlay) && ref($overlay) ne 'HASH';
    return 0;
}

sub list {
    my ($self) = @_;
    return [ sort keys %{ $self->{overlays} || {} } ];
}

sub active_overlays {
    my ($self) = @_;
    my @active;
    for my $name (@{ $self->{order} || [] }) {
        my $overlay = $self->{overlays}->{$name};
        next unless $overlay;
        my $enabled = 1;
        if (ref($overlay) eq 'HASH') {
            $enabled = $overlay->{enabled} ? 1 : 0;
        }
        elsif (ref($overlay)) {
            $enabled = exists $overlay->{enabled} ? ($overlay->{enabled} ? 1 : 0) : 1;
        }
        next unless $enabled;
        push @active, $overlay;
    }
    return \@active;
}

sub is_enabled {
    my ($self, $name) = @_;
    return 0 unless defined $name;
    my $overlay = $self->{overlays}->{$name};
    return 0 unless $overlay;
    return 1 unless ref($overlay) && exists $overlay->{enabled};
    return $overlay->{enabled} ? 1 : 0;
}

sub get {
    my ($self, $name) = @_;
    return undef unless defined $name;
    return $self->{overlays}->{$name};
}

sub reset {
    my ($self) = @_;
    $self->{overlays} = {};
    $self->{order} = [];
    return $self;
}

sub dispose {
    my ($self) = @_;
    $self->{initialized} = 0;
    $self->{overlays} = {};
    $self->{order} = [];
    return $self;
}

sub is_initialized {
    my ($self) = @_;
    return $self->{initialized} ? 1 : 0;
}

1;
