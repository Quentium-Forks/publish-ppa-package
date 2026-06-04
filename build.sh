#!/usr/bin/env bash

set -e
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update &&
    sudo apt-get install -y gpg debmake debhelper devscripts equivs \
        distro-info-data distro-info software-properties-common

echo "::group::Importing GPG private key..."
echo "Importing GPG private key..."

GPG_KEY_ID=$(echo "$GPG_PRIVATE_KEY" | gpg --import-options show-only --import | sed -n '2s/^\s*//p')
echo $GPG_KEY_ID
echo "$GPG_PRIVATE_KEY" | gpg --batch --passphrase "$GPG_PASSPHRASE" --import

echo "Checking GPG expirations..."
if [[ $(gpg --list-keys | grep expired) ]]; then
    echo "GPG key has expired. Please update your GPG key." >&2
    exit 1
fi

echo "::endgroup::"

echo "::group::Adding PPA..."
# Add extra PPA if it's been set
if [[ -n "$EXTRA_PPA" ]]; then
    for ppa in $EXTRA_PPA; do
        echo "Adding PPA: $ppa"
        sudo add-apt-repository -y ppa:$ppa
    done
fi
sudo apt-get update
echo "::endgroup::"

if [[ -z "$SERIES" ]]; then
    SERIES=$(distro-info --supported)
fi

# Add extra series if it's been set
if [[ -n "$EXTRA_SERIES" ]]; then
    SERIES="$EXTRA_SERIES $SERIES"
fi

# Reorder series to build the oldest one first using distro-info --all
SERIES=$(distro-info --all | grep -E "($(echo $SERIES | tr ' ' '|'))" | awk '{print $1}')

if [[ -z "$REVISION" ]]; then
    REVISION=1
fi

if [[ -z "$NEW_VERSION_TEMPLATE" ]]; then
    NEW_VERSION_TEMPLATE="{VERSION}-ppa{REVISION}~ubuntu{SERIES_VERSION}"
fi

include_orig_source=1

rm -rf /tmp/workspace && mkdir -p /tmp/workspace/source

cp $TARBALL /tmp/workspace/source
if [[ -n $DEBIAN_DIR ]]; then
    cp -r $DEBIAN_DIR /tmp/workspace/debian
fi

for s in $SERIES; do
    ubuntu_version=$(distro-info --series $s -r | cut -d' ' -f1)

    echo "::group::Building deb for: $ubuntu_version ($s)"

    rm -rf "/tmp/$s" && cp -r /tmp/workspace "/tmp/$s" && cd "/tmp/$s/source"
    tar -xf ./* && cd ./*/

    echo "Making non-native package..."
    debmake $DEBMAKE_ARGUMENTS

    if [[ -n $DEBIAN_DIR ]]; then
        # restore the custom debian directory
        cp -r /tmp/$s/debian/* debian/
    fi

    # Extract the package name from the debian changelog
    package=$(dpkg-parsechangelog --show-field Source)
    pkg_version=$(dpkg-parsechangelog --show-field Version | cut -d- -f1)

    # Create the debian changelog
    rm -rf debian/changelog

    # Generate the version using NEW_VERSION_TEMPLATE
    newversion=$(echo "$NEW_VERSION_TEMPLATE" | sed "s/{VERSION}/$pkg_version/g" | sed "s/{REVISION}/$REVISION/g" | sed "s/{SERIES_VERSION}/$ubuntu_version/g" | sed "s/{SERIES}/$s/g")

    echo "New version: $newversion"

    # Use provided changelog if KEEP_CHANGELOG is set
    if [[ -n $KEEP_CHANGELOG ]]; then
        # Ensure the changelog exists in the $DEBIAN_DIR
        if [[ ! -f $DEBIAN_DIR/changelog ]]; then
            echo "KEEP_CHANGELOG is set, but the changelog file does not exist"
            echo "Please provide a changelog file in the DEBIAN_DIR directory."
            exit 1
        fi

        new_revision=$(echo "$newversion" | cut -d- -f2)
        # Replace the package name, revision, distribution, and urgency in the changelog
        sed -E "s/^(\S+) \(([^-]+)-([^)]+)\) ([^;]+); urgency=(\S+)/$package (\2-$new_revision) $s; urgency=medium/" "$DEBIAN_DIR/changelog" \
            > debian/changelog

        echo "Changelog after replacement:"
        cat debian/changelog
    else
        dch --create --distribution "$s" \
            --package "$package" \
            --newversion "$newversion" \
            "New upstream release"
    fi

    # Install build dependencies
    sudo mk-build-deps --install --remove debian/control

    # mk-build-deps will generate .buildinfo and .changes files, remove them, otherwise debuild will fail
    rm -vf ./*.buildinfo ./*.changes

    echo "Building package..."

    if [[ $include_orig_source -eq 1 ]]; then
        source_option="-sa"
        include_orig_source=0
    else
        source_option="-sd"
    fi

    debuild -S "$source_option" \
        -k"$GPG_KEY_ID" \
        -p"gpg --batch --passphrase "$GPG_PASSPHRASE" --pinentry-mode loopback"

    cat /etc/dput.cf

    while true; do
        if dput ppa:$REPOSITORY ../*.changes; then
            echo "Uploaded $package to $REPOSITORY"
            break
        fi
    done

    echo "::endgroup::"
done
