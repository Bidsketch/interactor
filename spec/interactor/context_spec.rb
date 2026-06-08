module Interactor
  describe Context do
    describe ".build" do
      it "converts the given hash to a context" do
        context = Context.build(foo: "bar")

        expect(context).to be_a(Context)
        expect(context.foo).to eq("bar")
      end

      it "builds an empty context if no hash is given" do
        context = Context.build

        expect(context).to be_a(Context)
        expect(context.send(:table)).to eq({})
      end

      it "doesn't affect the original hash" do
        hash = {foo: "bar"}
        context = Context.build(hash)

        expect(context).to be_a(Context)
        expect {
          context.foo = "baz"
        }.not_to change {
          hash[:foo]
        }
      end

      it "preserves an already built context" do
        context1 = Context.build(foo: "bar")
        context2 = Context.build(context1)

        expect(context2).to be_a(Context)
        expect {
          context2.foo = "baz"
        }.to change {
          context1.foo
        }.from("bar").to("baz")
      end
    end

    describe "#success?" do
      let(:context) { Context.build }

      it "is true by default" do
        expect(context.success?).to eq(true)
      end
    end

    describe "#failure?" do
      let(:context) { Context.build }

      it "is false by default" do
        expect(context.failure?).to eq(false)
      end
    end

    describe "#fail!" do
      let(:context) { Context.build(foo: "bar") }

      it "sets success to false" do
        expect {
          begin
            context.fail!
          rescue
            nil
          end
        }.to change {
          context.success?
        }.from(true).to(false)
      end

      it "sets failure to true" do
        expect {
          begin
            context.fail!
          rescue
            nil
          end
        }.to change {
          context.failure?
        }.from(false).to(true)
      end

      it "preserves failure" do
        begin
          context.fail!
        rescue
          nil
        end

        expect {
          begin
            context.fail!
          rescue
            nil
          end
        }.not_to change {
          context.failure?
        }
      end

      it "preserves the context" do
        expect {
          begin
            context.fail!
          rescue
            nil
          end
        }.not_to change {
          context.foo
        }
      end

      it "updates the context" do
        expect {
          begin
            context.fail!(foo: "baz")
          rescue
            nil
          end
        }.to change {
          context.foo
        }.from("bar").to("baz")
      end

      it "updates the context with a string key" do
        expect {
          begin
            context.fail!("foo" => "baz")
          rescue
            nil
          end
        }.to change {
          context.foo
        }.from("bar").to("baz")
      end

      it "raises failure" do
        expect {
          context.fail!
        }.to raise_error(Failure)
      end

      it "makes the context available from the failure" do
        context.fail!
      rescue Failure => error
        expect(error.context).to eq(context)
      end
    end

    describe "#halt!" do
      let(:context) { Context.build(foo: "bar") }

      it "sets success to true" do
        begin
          context.halt!
        rescue
          nil
        end
        expect(context).to be_a_success
      end

      it "sets failure to false" do
        begin
          context.halt!
        rescue
          nil
        end
        expect(context).to_not be_a_failure
      end

      it "preserves failure" do
        begin
          context.fail!
        rescue
          nil
        end

        expect {
          begin
            context.halt!
          rescue
            nil
          end
        }.not_to change {
          context.failure?
        }
      end

      it "sets halted to true" do
        expect {
          begin
            context.halt!
          rescue
            nil
          end
        }.to change {
          context.halted?
        }.from(false).to(true)
      end

      it "preserves the context" do
        expect {
          begin
            context.halt!
          rescue
            nil
          end
        }.not_to change {
          context.foo
        }
      end

      it "updates the context" do
        expect {
          begin
            context.halt!(foo: "baz")
          rescue
            nil
          end
        }.to change {
          context.foo
        }.from("bar").to("baz")
      end

      it "to raise a Halt failure" do
        expect {
          context.halt!
        }.to raise_error(Halt)
      end

      it "makes the context available from the failure" do
        context.halt!
      rescue Halt => error
        expect(error.context).to eq(context)
      end
    end

    describe "#called!" do
      let(:context) { Context.build }
      let(:instance1) { double(:instance1) }
      let(:instance2) { double(:instance2) }

      it "appends to the internal list of called instances" do
        expect {
          context.called!(instance1)
          context.called!(instance2)
        }.to change {
          context._called
        }.from([]).to([instance1, instance2])
      end
    end

    describe "#rollback!" do
      let(:context) { Context.build }
      let(:instance1) { double(:instance1) }
      let(:instance2) { double(:instance2) }

      before do
        allow(context).to receive(:_called) { [instance1, instance2] }
      end

      it "rolls back each instance in reverse order" do
        expect(instance2).to receive(:rollback).once.with(no_args).ordered
        expect(instance1).to receive(:rollback).once.with(no_args).ordered

        context.rollback!
      end

      it "ignores subsequent attempts" do
        expect(instance2).to receive(:rollback).once
        expect(instance1).to receive(:rollback).once

        context.rollback!
        context.rollback!
      end
    end

    describe "#_called" do
      let(:context) { Context.build }

      it "is empty by default" do
        expect(context._called).to eq([])
      end
    end

    describe "dynamic attributes" do
      let(:context) { Context.build }

      it "sets and reads attributes via method syntax" do
        context.foo = "bar"
        expect(context.foo).to eq("bar")
      end

      it "returns nil for unset attributes" do
        expect(context.missing_key).to be_nil
      end

      it "overwrites previously set attributes" do
        context.foo = "bar"
        context.foo = "baz"
        expect(context.foo).to eq("baz")
      end

      it "responds to setter methods" do
        expect(context.respond_to?(:foo=)).to eq(true)
      end

      it "responds to getter methods only after the key is set" do
        expect(context.respond_to?(:foo)).to eq(false)
        context.foo = "bar"
        expect(context.respond_to?(:foo)).to eq(true)
      end

      it "normalises string keys to symbols" do
        context["foo"] = "bar"
        expect(context.foo).to eq("bar")
        expect(context[:foo]).to eq("bar")
      end
    end

    describe "#[] and #[]=" do
      let(:context) { Context.build }

      it "reads and writes with symbol keys" do
        context[:foo] = "bar"
        expect(context[:foo]).to eq("bar")
      end

      it "normalises string keys on write" do
        context["foo"] = "bar"
        expect(context[:foo]).to eq("bar")
      end

      it "normalises string keys on read" do
        context[:foo] = "bar"
        expect(context["foo"]).to eq("bar")
      end
    end

    describe "#to_h" do
      it "returns user-set attributes as a hash" do
        context = Context.build(foo: "bar", baz: 42)
        expect(context.to_h).to eq(foo: "bar", baz: 42)
      end

      it "does not include internal state flags" do
        context = Context.build(foo: "bar")
        begin
          context.fail!
        rescue
          nil
        end
        hash = context.to_h
        expect(hash.keys).not_to include(:failure, :success, :halted)
      end

      it "returns a copy that does not affect the context" do
        context = Context.build(foo: "bar")
        hash = context.to_h
        hash[:foo] = "mutated"
        expect(context.foo).to eq("bar")
      end
    end

    describe "#==" do
      it "is equal to another context with the same attributes" do
        context1 = Context.build(foo: "bar")
        context2 = Context.build(foo: "bar")
        expect(context1).to eq(context2)
      end

      it "is not equal to a context with different attributes" do
        context1 = Context.build(foo: "bar")
        context2 = Context.build(foo: "baz")
        expect(context1).not_to eq(context2)
      end

      it "is not equal to a plain hash" do
        context = Context.build(foo: "bar")
        expect(context).not_to eq(foo: "bar")
      end
    end

    describe "#eql? and #hash" do
      it "two contexts with the same attributes are eql?" do
        context1 = Context.build(foo: "bar")
        context2 = Context.build(foo: "bar")
        expect(context1.eql?(context2)).to eq(true)
      end

      it "two contexts with different attributes are not eql?" do
        context1 = Context.build(foo: "bar")
        context2 = Context.build(foo: "baz")
        expect(context1.eql?(context2)).to eq(false)
      end

      it "equal contexts have the same hash value" do
        context1 = Context.build(foo: "bar")
        context2 = Context.build(foo: "bar")
        expect(context1.hash).to eq(context2.hash)
      end

      it "can be used as a Hash key with value semantics" do
        context1 = Context.build(foo: "bar")
        context2 = Context.build(foo: "bar")
        h = {context1 => :found}
        expect(h[context2]).to eq(:found)
      end
    end

    describe "#dup (initialize_copy)" do
      let(:instance1) { double(:instance1) }
      let(:instance2) { double(:instance2) }

      it "dups the @table so attribute mutations are isolated" do
        original = Context.build(foo: "bar")
        copy = original.dup
        copy.foo = "baz"
        expect(original.foo).to eq("bar")
      end

      it "dups @called so rollback lists are independent" do
        original = Context.build
        original.called!(instance1)
        copy = original.dup
        copy.called!(instance2)
        expect(original._called).to eq([instance1])
        expect(copy._called).to eq([instance1, instance2])
      end

      it "resets failure state so a dup of a failed context starts fresh" do
        original = Context.build(foo: "bar")
        begin
          original.fail!
        rescue
          nil
        end
        copy = original.dup
        expect(copy.failure?).to eq(false)
        expect(copy.success?).to eq(true)
      end

      it "resets halted state so a dup of a halted context starts fresh" do
        original = Context.build(foo: "bar")
        begin
          original.halt!
        rescue
          nil
        end
        copy = original.dup
        expect(copy.halted?).to eq(false)
      end
    end

    describe "OpenStruct removal" do
      it "does not inherit from OpenStruct" do
        expect(Context.superclass).to eq(Object)
      end
    end

    describe "#deconstruct_keys" do
      let(:context) { Context.build(foo: :bar) }

      let(:deconstructed) { context.deconstruct_keys([:foo, :success, :failure, :halted]) }

      it "deconstructs as hash pattern" do
        expect(deconstructed[:foo]).to eq(:bar)
      end

      it "includes success and failure" do
        expect(deconstructed[:success]).to eq(true)
        expect(deconstructed[:failure]).to eq(false)
      end

      it "includes halted as false by default" do
        expect(deconstructed[:halted]).to eq(false)
      end

      context "when halted" do
        before do
          context.halt!
        rescue Halt
          nil
        end

        it "includes halted as true" do
          expect(context.deconstruct_keys(nil)[:halted]).to eq(true)
        end

        it "supports rightward assignment for halted:" do
          context => {halted:}
          expect(halted).to be(true)
        end
      end
    end
  end
end
