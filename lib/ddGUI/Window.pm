package ddGUI::Window;

use 5.010001;
use strict;
use warnings;

BEGIN {
	$ddGUI::Window::AUTHORITY = 'cpan:TOBYINK';
	$ddGUI::Window::VERSION   = '0.002';
}

use Moo;

use B 'perlstring';
use Prima qw( Application DetailedOutline PodView );
use Scalar::Util qw( blessed reftype refaddr );
use Types::Standard -types;

has title   => (is => "ro",   isa => Str,              required => 1);
has items   => (is => "ro",   isa => ArrayRef,         required => 1);
has $_      => (is => "lazy", isa => Object,           builder => 1) for qw( window outline textview );
has size    => (is => "ro",   isa => Tuple[Int, Int],  default => sub { [640, 480] });
has headers => (is => "ro",   isa => Tuple[Str, Str],  default => sub { ['Path', 'Value'] });
has vars    => (is => "lazy", isa => ArrayRef[Str],    builder => 1);
has _seen   => (is => "rw",   isa => HashRef[Str],     default => sub { +{} });

sub _build_window {
	my $self = shift;
	
	return 'Prima::MainWindow'->new(
		text      => $self->title,
		size      => $self->size,
		autoClose => 1,
	);
}

sub _build_outline {
	my $self = shift;
	
	return $self->window->insert(
		'Prima::DetailedOutline',
		columns   => 2,
		origin    => [0, 0],
		size      => [ $self->size->[0] / 3, $self->size->[1] ],
		headers   => $self->headers,
		items     => $self->_prepared_items,
		onSelectItem => sub {
			my $outline = $_[0];
			my ($item)  = $outline->get_item($_[1][0][0]);
			my $data    = $item->[0][2];
			my $path    = $item->[0][3];
			$self->_display_node( $path, $data );
		},
	);
}

sub _build_textview {
	my $self = shift;
	
	$self->window->insert(
		'Prima::PodView',
		origin    => [ $self->size->[0] / 3, 0 ],
		size      => [ $self->size->[0] * 2 / 3, $self->size->[1] ],
	);
}

sub execute {
	my $self = shift;
	
	# ensure widgets are built
	$self->$_ for qw( window outline textview );
	
	$self->window->execute;
}

sub _display_node {
	my $self = shift;
	my ($path, $item) = @_;
	
	my $tv = $self->textview;
	$tv->open_read;
	$tv->{readState}{createIndex} = [];
	$tv->read("=head1 VARIABLE\n\n$path\n\n");
	if (!defined($item)) {
		$tv->read("=head1 TYPE\n\nUndefined.\n\n");
	}
	elsif (!ref($item)) {
		$tv->read("=head1 TYPE\n\nNon-reference scalar.\n\n");
		$tv->read("=head1 VALUE\n\nC<< ${\ perlstring($item)} >>\n\n");
	}
	else {
		$tv->read("=head1 TYPE\n\n");
		$tv->read("Blessed: ${\ ref($item)}.\n\n") if blessed($item);
		$tv->read("Reference type: ${\ reftype($item)}.\n\n");
		$tv->read("Reference address: ${\ sprintf '0x%08X', refaddr($item)}.\n\n");
		
		if (blessed($item)) {
			if ('Class::MOP'->can('class_of') and my $meta = Class::MOP::class_of($item)) {
				$self->_display_moose($path, $item, $meta);
			}
		}
	}
	$tv->close_read;
}

sub _display_moose {
	my $self = shift;
	my ($path, $item, $meta) = @_;
	my $tv = $self->textview;
	
	my %d = (
		SUPERCLASSES => [ $meta->linearized_isa ],
		SUBCLASSES   => [ sort $meta->subclasses ],
		ROLES        => [ sort map $_->name, $meta->calculate_all_roles_with_inheritance ],
		METHODS      => [ sort map $_->name, $meta->get_all_methods ],
	);
	shift @{$d{SUPERCLASSES}}; # itself
	for my $h (qw/ SUPERCLASSES SUBCLASSES ROLES METHODS /) {
		$tv->read("=head1 $h\n\n");
		if (@{$d{$h}}) {
			$tv->read(join("; ", @{$d{$h}}).".\n\n");
		}
		else {
			$tv->read("(none).\n\n");
		}
	}
	
	$tv->read("=head1 ATTRIBUTES\n\n");
	
	if (!$meta->get_all_attributes) {
		$tv->read("(none)");
		return;
	}
	
	$tv->read("=over\n\n");
	for my $attr ($meta->get_all_attributes) {
		$tv->read(
			"=item *\n\nB<< ${\ $attr->name } >>"
			. "${\( $attr->has_documentation ? (' - '.$attr->documentation) : '' )}\n\n"
		);
		if ($attr->has_value($item)) {
			$tv->read("${\ Type::Tiny::_dd($attr->get_raw_value($item)) }\n\n");
		}
		else {
			$tv->read("Unset\n\n");
		}
	}
	$tv->read("=back\n\n");
}

sub _build_vars {
	my $self = shift;
	my $pfx  = $Data::Dumper::Varname;
	return [
		map "\$$pfx$_", 1 .. scalar(@{$self->items})
	];
}

sub _prepared_items {
	my $self = shift;
	$self->_seen({});
	my $i;
	return [
		map { ++$i; $self->_item_to_arrayref($self->vars->[$i-1], $_, $self->vars->[$i-1]) } @{ $self->items }
	];
}

sub _item_to_arrayref {
	my $self = shift;
	my ($label, $item, $path) = @_;
	
	if (!defined($item)) {
		return [[ $label, "(undef)", $item, $path ], [], 1, undef];
	}
	
	if (!ref($item)) {
		return [[ $label, perlstring($item), $item, $path ], [], 1, undef];
	}
	
	if (exists $self->_seen->{ refaddr($item) }) {
		my $is = $self->_seen->{ refaddr($item) };
		return [[ $label, "= $is", $item, $path ], [], 1, undef];
	}
	
	$self->_seen->{ refaddr($item) } = $path;
	
	my @internals;
	
	if (reftype($item) eq 'ARRAY') {
		my $i;
		@internals = map { ++$i; $self->_item_to_arrayref("[$i]", $_, "$path\->[$i]") } @$item;
	}
	if (reftype($item) eq 'HASH') {
		my $i;
		@internals = map { $self->_item_to_arrayref("{$_}", $item->{$_}, "$path\->{$_}") } sort keys %$item;
	}
	
	return [[ $label, '['.ref($item).']', $item, $path ], \@internals, !blessed($item), undef ];
}

1;

__END__

=pod

=encoding utf-8

=head1 NAME

ddGUI::Window - all the Prima stuff for Data::Dumper::GUI

=head1 DESCRIPTION

No user-serviceable parts within.

=head1 BUGS

Please report any bugs to
L<http://rt.cpan.org/Dist/Display.html?Queue=Data-Dumper-GUI>.

=head1 SEE ALSO

L<Data::Dumper::GUI>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2013 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 DISCLAIMER OF WARRANTIES

THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.

