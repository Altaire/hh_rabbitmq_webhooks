#!/bin/sh

debuild --no-tgz-check -I.git -b "$@"