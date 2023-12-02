#!/usr/bin/env bash
set -e

cd -- "$(dirname "$(readlink -f "$0")")" &> /dev/null

if [[ ! -f "inter/chain.crt" ]] || [[ ! -f "inter/inter.key" ]]
then
  rm -rf inter/*

  if [[ ! -f "ca/ca.crt" ]]
  then
    # initialize ca directory
    rm -rf ca/*
    touch ca/index
    echo "00" > ca/serial
  
    # generate key for root ca
    openssl genrsa \
      -out ca/ca.key \
      4096
  
    # generate root ca
    openssl req \
      -config ca.config \
      -key ca/ca.key \
      -new \
      -x509 \
      -extensions v3_ca \
      -days 36500 \
      -out ca/ca.crt
  fi
  # generate key for inter ca
  openssl genrsa -out inter/inter.key 4096

  # generate certificate sing request for inter ca
  openssl req \
    -config inter.config \
    -key inter/inter.key \
    -new \
    -sha256 \
    -out inter/inter.csr

  # sing inter ca with ca
   openssl ca \
     -batch \
     -config ca.config \
     -extensions v3_intermediate_ca \
     -days 3650 \
     -notext \
     -md sha256 \
     -in inter/inter.csr \
     -out inter/inter.crt

  cat inter/inter.crt ca/ca.crt > inter/chain.crt
fi