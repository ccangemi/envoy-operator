# A test catalog image. Build the catalog content first:
#   hack/build-catalog.sh build/catalog bundle=<bundle image>
FROM quay.io/operator-framework/opm:v1.74.0
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]
ADD build/catalog /configs
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]
LABEL operators.operatorframework.io.index.configs.v1=/configs
