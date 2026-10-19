# palmy — a Wayland UI toolkit in pure Odin
#
#   make            build every example into ./bin
#   make test       run the headless test suite
#   make run-todo   build and run one example
#   make shots      render the documentation screenshots
#   make distro     build the Palmy distribution (see distro/Makefile)

ODIN ?= odin
FLAGS ?= -o:speed
BIN := bin
EXAMPLES := counter todo gallery pixels

.PHONY: all test clean shots check distro $(addprefix run-,$(EXAMPLES))

all: $(addprefix $(BIN)/,$(EXAMPLES))

$(BIN)/%: examples/% $(wildcard palmy/*.odin) | $(BIN)
	$(ODIN) build $< $(FLAGS) -out:$@

$(BIN):
	@mkdir -p $(BIN)

test:
	$(ODIN) test tests

check:
	$(ODIN) check palmy -no-entry-point
	$(ODIN) check tests -no-entry-point

run-%: $(BIN)/%
	./$<

shots: $(BIN)/gallery
	@mkdir -p docs
	./$(BIN)/gallery render docs/components.png 0
	./$(BIN)/gallery render docs/colors.png 1
	./$(BIN)/gallery render docs/type.png 2

clean:
	rm -rf $(BIN)

distro:
	$(MAKE) -C distro
