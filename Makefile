# Standard ERB files (1:1 mapping)
ERBS := $(addprefix config/,$(patsubst %.erb,%,$(wildcard *.erb */*.erb */*/*.erb */*/*/*.erb)))

.PHONY: clean all check deploy deploy-compose

all: $(ERBS)

# Standard ERB rendering - this defines the ERBS targets
config/%: %.erb render.rb services.yml $(wildcard config.local.yml)
	mkdir -p $(dir $@)
	./render.rb < $(patsubst config/%,%,$@).erb > $@

clean:
	rm -rf config/

check: all
	promtool check config config/prometheus/prometheus.yml
	amtool check-config config/alertmanager/alertmanager.yml
	docker-compose -f config/docker-compose.yml config > /dev/null

install: all
	sudo rsync -av config/ /opt/mediaserver/config/
