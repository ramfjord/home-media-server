# Standard ERB files (1:1 mapping)
ERBS := $(addprefix config/,$(patsubst %.erb,%,$(wildcard *.erb */*.erb */*/*.erb */*/*/*.erb)))

# Extract dockerized services from services.yml
DOCKERIZED_SERVICES := $(shell yq eval '.services[] | select(.docker_config != null) | .name' services.yml 2>/dev/null)

.PHONY: clean all check deploy users $(addprefix deploy-,$(DOCKERIZED_SERVICES))

all: $(ERBS)

clean:
	rm -rf config/

users:
	script/make_users.sh

config:
	mkdir config
	chown $(USER):mediaserver config

# Standard ERB rendering - this defines the ERBS targets
config/%: %.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	./render.rb < $(patsubst config/%,%,$@).erb > $@
	@service=$$(echo $@ | cut -d'/' -f2); \
	if grep -q "name: $$service" services.yml; then sudo chown -R $$service:mediaserver config/$$service; fi

check: all
	# TODO convert these to use the container versions of promtool/amtool
	promtool check config config/prometheus/prometheus.yml
	amtool check-config config/alertmanager/alertmanager.yml
	docker-compose -f config/docker-compose.yml config > /dev/null
	docker run --rm \
		-v $(CURDIR)/config/otelcol:/etc/otelcol \
		otel/opentelemetry-collector-contrib:latest \
		validate --config=/etc/otelcol/otelcol-config.yaml

install: check
	sudo rsync -av config/ /opt/mediaserver/config/

# Deploy a single service: stop, update config, start
deploy-%: config/docker-compose.yml
	docker-compose -f config/docker-compose.yml stop $* || true
	make install
	docker-compose -f config/docker-compose.yml up -d $*
