# Standard ERB files (1:1 mapping)
ERBS := $(patsubst %.erb,%,$(wildcard *.erb prometheus/*/*.erb prometheus/*.erb alertmanager/*.erb))

# All generated files
GENERATED := $(ERBS)

.PHONY: clean all check deploy deploy-compose gitignore

all: $(ERBS) docker-compose.yml gitignore

clean:
	rm -rf $(ERBS) docker-compose.yml

check: all
	promtool check config prometheus/prometheus.yml
	amtool check-config alertmanager/alertmanager.yml

deploy: check deploy-compose
	chown -R $(USER):prometheus prometheus/
	cp -r prometheus/* /etc/prometheus/
	sudo systemctl reload prometheus
	sudo systemctl reload prometheus-blackbox-exporter
	sudo cp -r alertmanager/* /etc/alertmanager/
	sudo chown -R root:root /etc/alertmanager
	sudo systemctl reload alertmanager

deploy-compose: docker-compose.yml
	sudo mkdir -p /opt/mediaserver
	sudo ln -sf $(CURDIR)/docker-compose.yml /opt/mediaserver/docker-compose.yml

# Standard ERB rendering (1:1 mapping)
$(ERBS): %: %.erb render.rb services.yml $(wildcard config.local.yml)
	./render.rb < $@.erb > $@

# Update .gitignore with generated files
gitignore:
	@echo "# Auto-generated files (do not edit this section)" > .gitignore.generated
	@for f in $(GENERATED); do echo "$$f" >> .gitignore.generated; done
	@echo "config.local.yml" >> .gitignore.generated
	@if [ -f .gitignore ]; then \
		sed '/^# Auto-generated files/,/^# End auto-generated/d' .gitignore > .gitignore.tmp && mv .gitignore.tmp .gitignore; \
	fi
	@cat .gitignore.generated >> .gitignore
	@echo "# End auto-generated" >> .gitignore
	@rm .gitignore.generated
