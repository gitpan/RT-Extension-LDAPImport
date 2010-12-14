package RT::Extension::LDAPImport;

our $VERSION = '0.31_03';

use warnings;
use strict;
use base qw(Class::Accessor);
__PACKAGE__->mk_accessors(qw(_ldap _group screendebug _dnlist));
use Carp;
use Net::LDAP;
use Data::Dumper;

=head1 NAME

RT::Extension::LDAPImport - Import Users from an LDAP store


=head1 SYNOPSIS

    use RT::Extension::LDAPImport;

=head1 METHODS

=head2 connect_ldap

Relies on the config variables $RT::LDAPHost,
$RT::LDAPUser and $RT::LDAPPassword being set
in your RT Config files.

 Set(LDAPHost,'my.ldap.host')
 Set(LDAPUSER,'me');
 Set(LDAPPassword,'mypass');

LDAPUser and LDAPPassword can be blank,
which will cause an anonymous bind.

LDAPHost can be a hostname or an ldap:// ldaps:// uri

=cut

sub connect_ldap {
    my $self = shift;

    my $ldap = Net::LDAP->new($RT::LDAPHost);
    $self->_debug("connecting to $RT::LDAPHost");
    unless ($ldap) {
        $self->_error("Can't connect to $RT::LDAPHost");
        return;
    }

    my $msg;
    if ($RT::LDAPUser) {
        $self->_debug("binding as $RT::LDAPUser");
        $msg = $ldap->bind($RT::LDAPUser, password => $RT::LDAPPassword);
    } else {
        $self->_debug("binding anonymously");
        $msg = $ldap->bind;
    }

    if ($msg->code) {
        $self->_error("LDAP bind failed " . $msg->error);
        return;
    }

    $self->_ldap($ldap);
    return $ldap;

}

=head2 run_user_search

Set up the appropriate arguments for a listing of users

=cut

sub run_user_search {
    my $self = shift;
    $self->_run_search(
        base   => $RT::LDAPBase,
        filter => $RT::LDAPFilter
    );

}

=head2 _run_search

Executes a search using the provided base and filter

Will connect to LDAP server using connect_ldap

=cut

sub _run_search {
    my $self = shift;
    my $ldap = $self->_ldap||$self->connect_ldap;
    my %args = @_;

    unless ($ldap) {
        $self->_error("fetching an LDAP connection failed");
        return;
    }

    $self->_debug("searching with base => '$args{base}' filter => '$args{filter}'");

    my $result = $ldap->search( base => $args{base},
                                filter => $args{filter} );

    if ($result->code) {
        $self->_error("LDAP search failed " . $result->error);
        return;
    }

    $self->_debug("search found ".$result->count." objects");
    return $result;

}

=head2 import_users import => 1|0

Takes the results of the search from run_search
and maps attributes from LDAP into RT::User attributes
using $RT::LDAPMapping.
Creates RT users if they don't already exist.

With no arguments, only prints debugging information.
Pass import => 1 to actually change data.

RT::LDAPMapping should be set in your RT_SiteConfig
file and looks like this.

 Set($LDAPMapping, { RTUserField => LDAPField, RTUserField => LDAPField });

RTUserField is the name of a field on an RT::User object
LDAPField can be a simple scalar and that attribute
will be looked up in LDAP.  

It can also be an arrayref, in which case each of the 
elements will be evaluated in turn.  Scalars will be
looked up in LDAP and concatenated together with a single
space.

If the value is a sub reference, it will be executed.
The sub should return a scalar, which will be examined.
If it is a scalar, the value will be looked up in LDAP.
If it is an arrayref, the values will be concatenated 
together with a single space.

=cut

sub import_users {
    my $self = shift;
    my %args = @_;

    my $results = $self->run_user_search;
    unless ( $results && $results->count ) {
        $self->_debug("No results found, no import");
        $self->disconnect_ldap;
        return;
    }

    my $mapping = $RT::LDAPMapping;
    return unless $self->_check_ldap_mapping( mapping => $mapping );

    $self->_dnlist({});

    my $done = 0; my $count = $results->count;
    while (my $entry = $results->shift_entry) {
        my $user = $self->_build_object( ldap_entry => $entry, skip => qr/(?i)^CF\./, mapping => $mapping );
        $user->{Name} ||= $user->{EmailAddress};
        unless ( $user->{Name} ) {
            $self->_warn("No Name or Emailaddress for user, skipping ".Dumper $user);
            next;
        }
        $self->_import_user( user => $user, ldap_entry => $entry, import => $args{import} );
        $done++;
        $self->_debug("Imported $done/$count users");
    }
    return 1;
}

=head2 _import_user

The user has run us with --import, so bring data in

=cut

sub _import_user {
    my $self = shift;
    my %args = @_;

    $self->_debug("Processing user $args{user}{Name}");
    $self->_dnlist->{lc $args{ldap_entry}->dn} = $args{user}{Name};

    $args{user} = $self->create_rt_user( %args );
    return unless $args{user};

    $self->add_user_to_group( %args );
    $self->add_custom_field_value( %args );

    return 1;
}

sub _show_user_info {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};
    my $rt_user = $args{rt_user};

    return unless $self->screendebug;

    print "\tRT Field\tRT Value -> LDAP Value\n";
    foreach my $key (sort keys %$user) {
        my $old_value;
        if ($rt_user) {
            eval { $old_value = $rt_user->$key() };
            if ($user->{$key} && $old_value eq $user->{$key}) {
                $old_value = 'unchanged';
            }
        }
        $old_value ||= 'unset';
        print "\t$key\t$old_value => $user->{$key}\n";
    }
    #$self->_debug(Dumper($user));
}

=head2 _check_ldap_mapping

Returns true is there is an LDAPMapping configured,
returns false, logs an error and disconnects from
ldap if there is no mapping.

=cut

sub _check_ldap_mapping {
    my $self = shift;
    my %args = @_;
    my $mapping = $args{mapping};

    my @rtfields = keys %{$mapping};
    unless ( @rtfields ) {
        $self->_error("No mapping found, can't import");
        $self->disconnect_ldap;
        return;
    }

    return 1;
}

=head2 _build_object

Builds up data from LDAP for importing
Returns a hash of user data ready for RT::User::Create

=cut

sub _build_object {
    my $self = shift;
    my %args = @_;
    my $mapping = $args{mapping};

    my $object = {};
    foreach my $rtfield ( keys %{$mapping} ) {
        next if $rtfield =~ $args{skip};
        my $ldap_attribute = $mapping->{$rtfield};

        my @attributes = $self->_parse_ldap_mapping($ldap_attribute);
        unless (@attributes) {
            $self->_error("Invalid LDAP mapping for $rtfield ".Dumper($ldap_attribute));
            next;
        }
        my @values;
        foreach my $attribute (@attributes) {
            #$self->_debug("fetching value for $attribute and storing it in $rtfield");
            # otherwise we'll pull 7 alternate names out of the Name field
            # this may want to be configurable
            push @values, scalar $args{ldap_entry}->get_value($attribute);
        }
        $object->{$rtfield} = join(' ',grep {defined} @values);
    }

    return $object;
}

=head3 _parse_ldap_map

Internal helper function for import_user
If we're passed an arrayref, it will recurse 
over each of the elements in case one of them is
another arrayref or subroutine.

If we're passed a subref, it executes the code
and recurses over each of the returned values
so that a returned array or arrayref will work.

If we're passed a scalar, returns that.

Returns a list of values that need to be concatenated
together.

=cut

sub _parse_ldap_mapping {
    my $self = shift;
    my $mapping = shift;

    if (ref $mapping eq 'ARRAY') {
        return map { $self->_parse_ldap_mapping($_) } @$mapping;
    } elsif (ref $mapping eq 'CODE') {
        return map { $self->_parse_ldap_mapping($_) } $mapping->()
    } elsif (ref $mapping) {
        $self->_error("Invalid type of LDAPMapping [$mapping]");
        return;
    } else {
        return $mapping;
    }
}

=head2 create_rt_user

Takes a hashref of args to pass to RT::User::Create
Will try loading the user and will only create a new
user if it can't find an existing user with the Name
or EmailAddress arg passed in.

If the $LDAPUpdateUsers variable is true, data in RT
will be clobbered with data in LDAP.  Otherwise we
will skip to the next user.

If $LDAPUpdateOnly is true, we will not create new users
but we will update existing ones.

=cut

sub create_rt_user {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};

    my $user_obj = $self->_load_rt_user(%args);

    if ($user_obj->Id) {
        my $message = "User $user->{Name} already exists as ".$user_obj->Id;
        if ($RT::LDAPUpdateUsers || $RT::LDAPUpdateOnly) {
            $self->_debug("$message, updating their data");
            if ($args{import}) {
                my @results = $user_obj->Update( ARGSRef => $user, AttributesRef => [keys %$user] );
                $self->_debug(join("\n",@results)||'no change');
            } else {
                $self->_debug("Found existing user $user->{Name} to update");
                $self->_show_user_info( %args, rt_user => $user_obj );
            }
        } else {
            $self->_debug("$message, skipping");
        }
    } else {
        if ( $RT::LDAPUpdateOnly ) {
            $self->_debug("User $user->{Name} doesn't exist in RT, skipping");
            return;
        } else {
            if ($args{import}) {
                my ($val, $msg) = $user_obj->Create( %$user, Privileged => 0 );

                unless ($val) {
                    $self->_error("couldn't create user_obj for $user->{Name}: $msg");
                    return;
                }
                $self->_debug("Created user for $user->{Name} with id ".$user_obj->Id);
            } else {
                print "Found new user $user->{Name} to create in RT\n";
                $self->_show_user_info( %args );
                return;
            }
        }
    }

    unless ($user_obj->Id) {
        $self->_error("We couldn't find or create $user->{Name}. This should never happen");
    }
    return $user_obj;

}

sub _load_rt_user {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};

    my $user_obj = RT::User->new($RT::SystemUser);

    $user_obj->Load( $user->{Name} );
    unless ($user_obj->Id) {
        $user_obj->LoadByEmail( $user->{EmailAddress} );
    }

    return $user_obj;
}

=head2 add_user_to_group

Adds new users to the group specified in the $LDAPGroupName
variable (defaults to 'Imported from LDAP')
You can avoid this if you set $LDAPSkipAutogeneratedGroup

=cut

sub add_user_to_group {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};

    return if $RT::LDAPSkipAutogeneratedGroup;

    my $group = $self->_group||$self->setup_group;

    my $principal = $user->PrincipalObj;

    if ($group->HasMember($principal)) {
        $self->_debug($user->Name . " already a member of " . $group->Name);
        return;
    }

    if ($args{import}) {
        my ($status, $msg) = $group->AddMember($principal->Id);
        if ($status) {
            $self->_debug("Added ".$user->Name." to ".$group->Name." [$msg]");
        } else {
            $self->_error("Couldn't add ".$user->Name." to ".$group->Name." [$msg]");
        }
        return $status;
    } else {
        $self->_debug("Would add to ".$group->Name);
        return;
    }
}

=head2 setup_group

Pulls the $LDAPGroupName object out of the DB or
creates it if we ened to do so.

=cut

sub setup_group  {
    my $self = shift;
    my $group_name = $RT::LDAPGroupName||'Imported from LDAP';
    my $group = RT::Group->new($RT::SystemUser);

    $group->LoadUserDefinedGroup( $group_name );
    unless ($group->Id) {
        my ($id,$msg) = $group->CreateUserDefinedGroup( Name => $group_name );
        unless ($id) {
            $self->_error("Can't create group $group_name [$msg]")
        }
    }

    $self->_group($group);
}

=head3 add_custom_field_value

Adds values to a Select (one|many) Custom Field.
The Custom Field should already exist, otherwise
this will throw an error and not import any data.

This could probably use some caching

=cut

sub add_custom_field_value {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};

    foreach my $rtfield ( keys %{$RT::LDAPMapping} ) {
        next unless $rtfield =~ /^CF\.(.+)$/i;
        my $cf_name = $1;
        my $ldap_attribute = $RT::LDAPMapping->{$rtfield};

        my @attributes = $self->_parse_ldap_mapping($ldap_attribute);
        unless (@attributes) {
            $self->_error("Invalid LDAP mapping for $rtfield ".Dumper($ldap_attribute));
            next;
        }
        my @values;
        foreach my $attribute (@attributes) {
            #$self->_debug("fetching value for $attribute and storing it in $rtfield");
            # otherwise we'll pull 7 alternate names out of the Name field
            # this may want to be configurable
            push @values, scalar $args{ldap_entry}->get_value($attribute);
        }
        my $cfv_name = join(' ',@values); 
        next unless $cfv_name;

        my $cf = RT::CustomField->new($RT::SystemUser);
        my ($status, $msg) = $cf->Load($cf_name);
        unless ($status) {
            $self->_error("Couldn't load CF [$cf_name]: $msg");
            next;
        }

        my $cfv = RT::CustomFieldValue->new($RT::SystemUser);
        $cfv->LoadByCols( CustomField => $cf->id, 
                          Name => $cfv_name );
        if ($cfv->id) {
            $self->_debug("Custom Field '$cf_name' already has '$cfv_name' for a value");
            next;
        }

        if ($args{import}) {
            ($status, $msg) = $cf->AddValue( Name => $cfv_name );
            if ($status) {
                $self->_debug("Added '$cfv_name' to Custom Field '$cf_name' [$msg]");
            } else {
                $self->_error("Couldn't add '$cfv_name' to '$cf_name' [$msg]");
            }
        } else {
            $self->_debug("Would add '$cfv_name' to Custom Field '$cf_name'");
        }
    }

    return;

}

=head2 import_groups import => 1|0

Takes the results of the search from run_group_search
and maps attributes from LDAP into RT::Group attributes
using $RT::LDAPGroupMapping.

Creates groups if they don't exist

Removes users from groups if they have been removed from the group on LDAP

With no arguments, only prints debugging information.
Pass import => 1 to actually change data.

=cut

sub import_groups {
    my $self = shift;
    my %args = @_;

    my $results = $self->run_group_search;
    unless ( $results && $results->count ) {
        $self->_debug("No results found, no group import");
        $self->disconnect_ldap;
        return;
    }

    my $mapping = $RT::LDAPGroupMapping;
    return unless $self->_check_ldap_mapping( mapping => $mapping );

    my $done = 0; my $count = $results->count;
    while (my $entry = $results->shift_entry) {
        my $group = $self->_build_object( ldap_entry => $entry, skip => qr/(?i)^Member_Attr/, mapping => $mapping );
        $group->{Description} ||= 'Imported from LDAP';
        unless ( $group->{Name} ) {
            $self->_warn("No Name for group, skipping ".Dumper $group);
            next;
        }
        $self->_import_group( %args, group => $group, ldap_entry => $entry );
        $done++;
        $self->_debug("Imported $done/$count groups");
    }
    return 1;
}

=head3 run_group_search

Set up the approviate arguments for a listing of users

=cut

sub run_group_search {
    my $self = shift;

    unless ($RT::LDAPGroupBase && $RT::LDAPGroupFilter) {
        $self->_warn("Not running a group import, configuration not set");
        return;
    }
    $self->_run_search(
        base   => $RT::LDAPGroupBase,
        filter => $RT::LDAPGroupFilter
    );

}


=head2 _import_group

The user has run us with --import, so bring data in

=cut

sub _import_group {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};
    my $ldap_entry = $args{ldap_entry};

    $self->_debug("Processing group $group->{Name}");
    my $group_obj = $self->create_rt_group( %args, group => $group );
    return if $args{import} and not $group_obj;
    $self->add_group_members( %args, name => $group->{Name}, group => $group_obj, ldap_entry => $ldap_entry );
    return;
}

=head2 create_rt_group

Takes a hashref of args to pass to RT::Group::Create
Will try loading the group and will only create a new
group if it can't find an existing group with the Name
or EmailAddress arg passed in.

If $LDAPUpdateOnly is true, we will not create new groups
but we will update existing ones.

There is currently no way to prevent Group data from being
clobbered from LDAP.

=cut

sub create_rt_group {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};

    my $group_obj = RT::Group->new($RT::SystemUser);
    $group_obj->LoadUserDefinedGroup( $group->{Name} );

    if ($group_obj->Id) {
        my $message = "Group $group->{Name} already exists as ".$group_obj->Id;
        if ($args{import}) {
            $self->_debug("$message, updating their data");
            my @results = $group_obj->Update( ARGSRef => $group, AttributesRef => [keys %$group] );
            $self->_debug(join("\n",@results)||'no change');
        } else {
            print "Found existing group $group->{Name} to update\n";
            $self->_show_group_info( %args, rt_group => $group_obj );
        }
    } else {
        if ( $RT::LDAPUpdateOnly ) {
            $self->_debug("Group $group->{Name} doesn't exist in RT, skipping");
            return;
        }

        if ($args{import}) {
            my ($val, $msg) = $group_obj->CreateUserDefinedGroup( %$group );
            unless ($val) {
                $self->_error("couldn't create group_obj for $group->{Name}: $msg");
                return;
            }
            $self->_debug("Created group for $group->{Name} with id ".$group_obj->Id);
        } else {
            print "Found new group $group->{Name} to create in RT\n";
            $self->_show_group_info( %args );
            return;
        }
    }

    unless ($group_obj->Id) {
        $self->_error("We couldn't find or create $group->{Name}. This should never happen");
    }
    return $group_obj;

}

=head3 add_group_members

Iterate over the list of DNs in the Member_Attr LDAP entry.
Look up the appropriate username from LDAP.
Add those users to the group.
Remove members of the RT Group who are no longer members
of the LDAP group.

=cut

sub add_group_members {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};
    my $groupname = $args{name};
    my $ldap_entry = $args{ldap_entry};

    $self->_debug("Processing group membership for $groupname");

    my $members = $self->_get_group_members_from_ldap(%args);

    unless (defined $members) {
        $self->_warn("No members found for $groupname in Member_Attr");
        return;
    }

    my $rt_group_members = {};
    if ($args{group}) {
        my $user_members = $group->UserMembersObj( Recursively => 0);
        while ( my $member = $user_members->Next ) {
            $rt_group_members->{$member->Name}++;
        }
    } elsif (not $args{import}) {
        $self->_debug("No group in RT, would create with members:");
    }

    my $dnlist = $self->_dnlist;
    foreach my $member (@$members) {
        my $username;
        if (exists $dnlist->{lc $member}) {
            next unless $username = $dnlist->{lc $member};
        } else {
            my $ldap_users = $self->_run_search(
                base   => $member,
                filter => $RT::LDAPFilter,
            );
            unless ( $ldap_users && $ldap_users->count ) {
                $dnlist->{lc $member} = undef;
                $self->_error("No user found for $member who should be a member of $groupname");
                next;
            }
            my $ldap_user = $ldap_users->shift_entry;
            $dnlist->{lc $member} = $username = $ldap_user->get_value($RT::LDAPMapping->{Name});
        }
        if ( delete $rt_group_members->{$username} ) {
            $self->_debug("\t$username\tin RT and LDAP");
            next;
        }
        $self->_debug($group ? "\t$username\tin LDAP, adding to RT" : "\t$username");
        next unless $args{import};

        my $rt_user = RT::User->new($RT::SystemUser);
        my ($res,$msg) = $rt_user->Load( $username );
        unless ($res) {
            $self->_warn("Unable to load $username: $msg");
            next;
        }
        ($res,$msg) = $group->AddMember($rt_user->PrincipalObj->Id);
        unless ($res) {
            $self->_warn("Failed to add $username to $groupname: $msg");
        }
    }

    for my $username (sort keys %$rt_group_members) {
        $self->_debug("\t$username\tin RT, not in LDAP, removing");
        next unless $args{import};

        my $rt_user = RT::User->new($RT::SystemUser);
        my ($res,$msg) = $rt_user->Load( $username );
        unless ($res) {
            $self->_warn("Unable to load $username: $msg");
            next;
        }
        ($res,$msg) = $group->DeleteMember($rt_user->PrincipalObj->Id);
        unless ($res) {
            $self->_warn("Failed to remove $username to $groupname: $msg");
        }
    }
}

sub _get_group_members_from_ldap {
    my $self = shift;
    my %args = @_;
    my $ldap_entry = $args{ldap_entry};

    my $mapping = $RT::LDAPGroupMapping;

    my $members = $ldap_entry->get_value($mapping->{Member_Attr}, asref => 1);
}


=head2 _show_group

Show debugging information about the group record we're going to import
when the groups reruns us with --import

=cut

sub _show_group {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};

    my $rt_group = RT::Group->new($RT::SystemUser);
    $rt_group->LoadUserDefinedGroup( $group->{Name} );

    if ( $rt_group->Id ) {
        print "Found existing group $group->{Name} to update\n";
        $self->_show_group_info( %args, rt_group => $rt_group );
    } else {
        print "Found new group $group->{Name} to create in RT\n";
        $self->_show_group_info( %args );
    }
}

sub _show_group_info {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};
    my $rt_group = $args{rt_group};

    return unless $self->screendebug;

    print "\tRT Field\tRT Value -> LDAP Value\n";
    foreach my $key (sort keys %$group) {
        my $old_value;
        if ($rt_group) {
            eval { $old_value = $rt_group->$key() };
            if ($group->{$key} && $old_value eq $group->{$key}) {
                $old_value = 'unchanged';
            }
        }
        $old_value ||= 'unset';
        print "\t$key\t$old_value => $group->{$key}\n";
    }
}


=head3 disconnect_ldap

Disconnects from the LDAP server

Takes no arguments, returns nothing

=cut

sub disconnect_ldap {
    my $self = shift;
    my $ldap = $self->_ldap;
    return unless $ldap;

    $ldap->unbind;
    $ldap->disconnect;
    return;
}

=head1 Utility Functions

=head3 screendebug

We always log to the RT log file with level debug 

This duplicates the messages to the screen

=cut

sub _debug {
    my $self = shift;
    my $msg  = shift;

    $RT::Logger->debug($msg);

    return unless $self->screendebug;
    print $msg, "\n";

}

sub _error {
    my $self = shift;
    my $msg  = shift;

    $RT::Logger->error($msg);
    print STDERR $msg, "\n";
}

sub _warn {
    my $self = shift;
    my $msg  = shift;

    $RT::Logger->warning($msg);
    print STDERR $msg, "\n";
}

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-rt-extension-ldapimport@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Kevin Falcone  C<< <falcone@bestpractical.com> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007, Best Practical Solutions, LLC.  All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut

1;
