package cli

import (
	"fmt"
	"strconv"
	"time"

	"github.com/AlecAivazis/survey/v2"
	"github.com/choria-io/fisk"
	"github.com/google/go-cmp/cmp"

	"sequin-cli/api"
	"sequin-cli/context"
)

type consumerConfig struct {
	ConsumerID       string
	Slug             string
	AckWaitMS        int
	MaxAckPending    int
	MaxDeliver       int
	MaxWaiting       int
	FilterKeyPattern string
	BatchSize        int
	NoAck            bool
	PendingOnly      bool
	LastN            int
	FirstN           int
	AckToken         string
	Force            bool
	UseDefaults      bool
}

func AddConsumerCommands(app *fisk.Application, config *Config) {
	consumer := app.Command("consumer", "Consumer related commands").Alias("con").Alias("c")

	addCheat("consumer", consumer)

	c := &consumerConfig{}

	consumer.Command("ls", "List consumers").Action(func(ctx *fisk.ParseContext) error {
		return consumerLs(ctx, config)
	})

	addCmd := consumer.Command("add", "Add a new consumer").Action(func(ctx *fisk.ParseContext) error {
		return consumerAdd(ctx, config, c)
	})
	addCmd.Arg("slug", "Slug for the new consumer").StringVar(&c.Slug)
	addCmd.Flag("ack-wait-ms", "Acknowledgement wait time in milliseconds").IntVar(&c.AckWaitMS)
	addCmd.Flag("max-ack-pending", "Maximum number of pending acknowledgements").IntVar(&c.MaxAckPending)
	addCmd.Flag("max-deliver", "Maximum number of delivery attempts").IntVar(&c.MaxDeliver)
	addCmd.Flag("max-waiting", "Maximum number of waiting messages").IntVar(&c.MaxWaiting)
	addCmd.Flag("filter", "Key pattern for message filtering").StringVar(&c.FilterKeyPattern)
	addCmd.Flag("defaults", "Use default values for non-required fields").BoolVar(&c.UseDefaults)

	infoCmd := consumer.Command("info", "Show consumer information").Action(func(ctx *fisk.ParseContext) error {
		return consumerInfo(ctx, config, c)
	})
	infoCmd.Arg("consumer-id", "ID of the consumer").StringVar(&c.ConsumerID)

	receiveCmd := consumer.Command("receive", "Receive messages for a consumer").Action(func(ctx *fisk.ParseContext) error {
		return consumerReceive(ctx, config, c)
	})
	receiveCmd.Arg("consumer-id", "ID of the consumer").StringVar(&c.ConsumerID)
	receiveCmd.Flag("batch-size", "Number of messages to fetch").Default("1").IntVar(&c.BatchSize)
	receiveCmd.Flag("no-ack", "Do not acknowledge messages").BoolVar(&c.NoAck)

	peekCmd := consumer.Command("peek", "Show messages for a consumer").Action(func(ctx *fisk.ParseContext) error {
		return consumerPeek(ctx, config, c)
	})
	peekCmd.Arg("consumer-id", "ID of the consumer").StringVar(&c.ConsumerID)
	peekCmd.Flag("pending", "Show only pending messages").BoolVar(&c.PendingOnly)
	peekCmd.Flag("last", "Show most recent N messages").IntVar(&c.LastN)
	peekCmd.Flag("first", "Show least recent N messages").IntVar(&c.FirstN)

	ackCmd := consumer.Command("ack", "Ack a message").Action(func(ctx *fisk.ParseContext) error {
		return consumerAck(ctx, config, c)
	})
	ackCmd.Arg("consumer-id", "ID of the consumer").StringVar(&c.ConsumerID)
	ackCmd.Arg("ack-token", "Ack token of the message to ack").StringVar(&c.AckToken)

	nackCmd := consumer.Command("nack", "Nack a message").Action(func(ctx *fisk.ParseContext) error {
		return consumerNack(ctx, config, c)
	})
	nackCmd.Arg("consumer-id", "ID of the consumer").StringVar(&c.ConsumerID)
	nackCmd.Arg("ack-id", "ID of the message to nack").StringVar(&c.AckToken)

	updateCmd := consumer.Command("edit", "Edit an existing consumer").Action(func(ctx *fisk.ParseContext) error {
		return consumerEdit(ctx, config, c)
	})
	updateCmd.Arg("consumer-id", "ID of the consumer").StringVar(&c.ConsumerID)
	updateCmd.Flag("ack-wait-ms", "Acknowledgement wait time in milliseconds").IntVar(&c.AckWaitMS)
	updateCmd.Flag("max-ack-pending", "Maximum number of pending acknowledgements").IntVar(&c.MaxAckPending)
	updateCmd.Flag("max-deliver", "Maximum number of delivery attempts").IntVar(&c.MaxDeliver)
	updateCmd.Flag("max-waiting", "Maximum number of waiting messages").IntVar(&c.MaxWaiting)
}

// Helper function to get the first available stream
func getFirstStream(ctx *context.Context) (string, error) {
	streams, err := api.FetchStreams(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to fetch streams: %w", err)
	}
	if len(streams) == 0 {
		return "", fmt.Errorf("no streams available")
	}
	return streams[0].ID, nil
}

func consumerLs(_ *fisk.ParseContext, config *Config) error {
	ctx, err := context.LoadContext(config.ContextName)
	if err != nil {
		fisk.Fatalf("failed to load context: %s", err)
	}

	streamID, err := getFirstStream(ctx)
	if err != nil {
		return err
	}

	if config.AsCurl {
		req, err := api.BuildFetchConsumers(ctx, streamID)
		if err != nil {
			return err
		}
		curlCmd, err := formatCurl(req)
		if err != nil {
			return err
		}

		fmt.Println(curlCmd)

		return nil
	}

	consumers, err := api.FetchConsumers(ctx, streamID)
	if err != nil {
		fisk.Fatalf("failed to fetch consumers: %s", err)
	}

	if len(consumers) == 0 {
		fmt.Println("No consumers found for this stream.")
		return nil
	}

	table := newTableWriter("Consumers")

	table.AddHeaders("ID", "Slug", "Max Ack Pending", "Max Deliver", "Created At")

	for _, consumer := range consumers {
		table.AddRow(
			consumer.ID,
			consumer.Slug,
			strconv.Itoa(consumer.MaxAckPending),
			strconv.Itoa(consumer.MaxDeliver),
			consumer.CreatedAt.Format(time.RFC3339),
		)
	}

	fmt.Print(table.Render())
	return nil
}

func consumerAdd(_ *fisk.ParseContext, config *Config, c *consumerConfig) error {
	ctx, err := context.LoadContext(config.ContextName)
	if err != nil {
		return fmt.Errorf("failed to load context: %w", err)
	}

	streamID, err := getFirstStream(ctx)
	if err != nil {
		return err
	}

	// Always prompt for required fields
	if c.Slug == "" {
		err = survey.AskOne(&survey.Input{
			Message: "Enter consumer slug:",
			Help:    "A unique identifier for this consumer.",
		}, &c.Slug, survey.WithValidator(survey.Required))
		if err != nil {
			return fmt.Errorf("failed to get user input: %w", err)
		}
	}

	if c.FilterKeyPattern == "" {
		err = survey.AskOne(&survey.Input{
			Message: "Enter key pattern for message filtering:",
			Help:    "A key pattern to filter which messages this consumer receives. Use '*' as a wildcard.",
		}, &c.FilterKeyPattern, survey.WithValidator(survey.Required))
		if err != nil {
			return fmt.Errorf("failed to get user input: %w", err)
		}
	}

	// Only prompt for non-required fields if --defaults is not set
	if !c.UseDefaults {
		if c.AckWaitMS == 0 {
			err = promptForInt("Enter acknowledgement wait time in milliseconds (optional):", &c.AckWaitMS)
			if err != nil {
				return err
			}
		}

		if c.MaxAckPending == 0 {
			err = promptForInt("Enter maximum number of pending acknowledgements (optional):", &c.MaxAckPending)
			if err != nil {
				return err
			}
		}

		if c.MaxDeliver == 0 {
			err = promptForInt("Enter maximum number of delivery attempts (optional):", &c.MaxDeliver)
			if err != nil {
				return err
			}
		}

		if c.MaxWaiting == 0 {
			err = promptForInt("Enter maximum number of waiting pull requests (optional):", &c.MaxWaiting)
			if err != nil {
				return err
			}
		}
	}

	createOptions := api.ConsumerCreateOptions{
		Slug:             c.Slug,
		StreamID:         streamID,
		FilterKeyPattern: c.FilterKeyPattern,
	}

	if c.AckWaitMS != 0 {
		createOptions.AckWaitMS = c.AckWaitMS
	}
	if c.MaxAckPending != 0 {
		createOptions.MaxAckPending = c.MaxAckPending
	}
	if c.MaxDeliver != 0 {
		createOptions.MaxDeliver = c.MaxDeliver
	}
	if c.MaxWaiting != 0 {
		createOptions.MaxWaiting = c.MaxWaiting
	}

	if config.AsCurl {
		req, err := api.BuildAddConsumer(ctx, createOptions)
		if err != nil {
			return err
		}
		curlCmd, err := formatCurl(req)
		if err != nil {
			return err
		}

		fmt.Println(curlCmd)

		return nil
	}

	consumer, err := api.AddConsumer(ctx, createOptions)
	if err != nil {
		fisk.Fatalf("failed to add consumer: %s", err)
	}

	// Display the created consumer information
	displayConsumerInfo(consumer)

	return nil
}

func displayConsumerInfo(consumer *api.Consumer) {
	cols := newColumns(fmt.Sprintf("Consumer %s created %s", consumer.ID, consumer.CreatedAt.Format(time.RFC3339)))
	cols.AddRow("ID", consumer.ID)
	cols.AddRow("Slug", consumer.Slug)
	cols.AddRow("Stream ID", consumer.StreamID)
	cols.AddRow("Ack Wait (ms)", strconv.Itoa(consumer.AckWaitMS))
	cols.AddRow("Max Ack Pending", strconv.Itoa(consumer.MaxAckPending))
	cols.AddRow("Max Deliver", strconv.Itoa(consumer.MaxDeliver))
	cols.AddRow("Max Waiting", strconv.Itoa(consumer.MaxWaiting))
	cols.AddRow("Filter", consumer.FilterKeyPattern)
	cols.AddRow("Created At", consumer.CreatedAt.Format(time.RFC3339))

	cols.Println()

	output, err := cols.Render()
	if err != nil {
		fisk.Fatalf("failed to render columns: %s", err)
	}

	fmt.Print(output)
}

func consumerInfo(_ *fisk.ParseContext, config *Config, c *consumerConfig) error {
	ctx, err := context.LoadContext(config.ContextName)
	if err != nil {
		fisk.Fatalf("failed to load context: %s", err)
	}

	streamID, err := getFirstStream(ctx)
	if err != nil {
		return err
	}

	if c.ConsumerID == "" {
		consumerID, err := promptForConsumer(ctx, streamID)
		if err != nil {
			return err
		}
		c.ConsumerID = consumerID
	}

	if config.AsCurl {
		req, err := api.BuildFetchConsumerInfo(ctx, streamID, c.ConsumerID)
		if err != nil {
			return err
		}
		curlCmd, err := formatCurl(req)
		if err != nil {
			return err
		}

		fmt.Println(curlCmd)

		return nil
	}

	consumer, err := api.FetchConsumerInfo(ctx, streamID, c.ConsumerID)
	if err != nil {
		fisk.Fatalf("failed to fetch consumer info: %s", err)
	}

	displayConsumerInfo(consumer)

	return nil
}
func consumerReceive(_ *fisk.ParseContext, config *Config, c *consumerConfig) error {
	ctx, err := context.LoadContext(config.ContextName)
	if err != nil {
		return err
	}

	streamID, err := getFirstStream(ctx)
	if err != nil {
		return err
	}

	if c.ConsumerID == "" {
		consumerID, err := promptForConsumer(ctx, streamID)
		if err != nil {
			return err
		}
		c.ConsumerID = consumerID
	}

	if config.AsCurl {
		req, err := api.BuildFetchNextMessages(ctx, streamID, c.ConsumerID, c.BatchSize)
		if err != nil {
			return err
		}
		curlCmd, err := formatCurl(req)
		if err != nil {
			return err
		}

		fmt.Println(curlCmd)

		return nil
	}

	messages, err := api.FetchNextMessages(ctx, streamID, c.ConsumerID, c.BatchSize)
	if err != nil {
		return err
	}

	if len(messages) == 0 {
		fmt.Println("No messages available.")
		return nil
	}

	for _, msg := range messages {
		fmt.Printf("Message (Ack Token: %s):\n", msg.AckToken)
		fmt.Printf("Key: %s\n", msg.Message.Key)
		fmt.Printf("Sequence: %d\n", msg.Message.Seq)
		fmt.Printf("\n%s\n", msg.Message.Data)

		if !c.NoAck {
			err := api.AckMessage(ctx, streamID, c.ConsumerID, msg.AckToken)
			if err != nil {
				return fmt.Errorf("failed to acknowledge message: %w", err)
			}
			fmt.Printf("Message acknowledged with token %s\n", msg.AckToken)
		}
	}

	return nil
}

func consumerPeek(_ *fisk.ParseContext, config *Config, c *consumerConfig) error {
	ctx, err := context.LoadContext(config.ContextName)
	if err != nil {
		return err
	}

	streamID, err := getFirstStream(ctx)
	if err != nil {
		return err
	}

	if c.ConsumerID == "" {
		consumerID, err := promptForConsumer(ctx, streamID)
		if err != nil {
			return err
		}
		c.ConsumerID = consumerID
	}

	if config.AsCurl {
		options := api.FetchMessagesOptions{
			StreamID:   streamID,
			ConsumerID: c.ConsumerID,
			Visible:    !c.PendingOnly, // Invert PendingOnly to get Visible
			Limit:      10,             // Default limit
			Order:      "seq_desc",     // Default order
		}

		if c.LastN > 0 {
			options.Limit = c.LastN
			options.Order = "seq_desc"
		} else if c.FirstN > 0 {
			options.Limit = c.FirstN
			options.Order = "seq_asc"
		}

		req, err := api.BuildFetchMessages(ctx, options)
		if err != nil {
			return err
		}
		curlCmd, err := formatCurl(req)
		if err != nil {
			return err
		}

		fmt.Println(curlCmd)

		return nil
	}

	options := api.FetchMessagesOptions{
		StreamID:   streamID,
		ConsumerID: c.ConsumerID,
		Visible:    !c.PendingOnly, // Invert PendingOnly to get Visible
		Limit:      10,             // Default limit
		Order:      "seq_desc",     // Default order
	}

	if c.LastN > 0 {
		options.Limit = c.LastN
		options.Order = "seq_desc"
	} else if c.FirstN > 0 {
		options.Limit = c.FirstN
		options.Order = "seq_asc"
	}

	messages, err := api.FetchMessages(ctx, options)
	if err != nil {
		fisk.Fatalf("Failed to fetch messages: %v", err)
	}

	if len(messages) == 0 {
		fmt.Println("No messages found.")
		return nil
	}

	for _, msg := range messages {
		fmt.Printf("Key: %s\n", msg.Message.Key)
		fmt.Printf("Sequence: %d\n", msg.Message.Seq)
		fmt.Printf("Deliver Count: %d\n", msg.Info.DeliverCount)
		fmt.Printf("Last Delivered At: %s\n", msg.Info.FormatLastDeliveredAt())
		fmt.Printf("Not Visible Until: %s\n", msg.Info.FormatNotVisibleUntil())
		if msg.Info.State != "" {
			fmt.Printf("State: %s\n", msg.Info.State)
		}
		fmt.Printf("\n%s\n", msg.Message.Data)
	}

	return nil
}

func consumerAck(_ *fisk.ParseContext, config *Config, c *consumerConfig) error {
	ctx, err := context.LoadContext(config.ContextName)
	if err != nil {
		return err
	}

	streamID, err := getFirstStream(ctx)
	if err != nil {
		return err
	}

	if config.AsCurl {
		req, err := api.BuildAckMessage(ctx, streamID, c.ConsumerID, c.AckToken)
		if err != nil {
			return err
		}
		curlCmd, err := formatCurl(req)
		if err != nil {
			return err
		}

		fmt.Println(curlCmd)

		return nil
	}

	err = api.AckMessage(ctx, streamID, c.ConsumerID, c.AckToken)
	if err != nil {
		return fmt.Errorf("failed to acknowledge message: %w", err)
	}

	fmt.Printf("Message acknowledged with token %s\n", c.AckToken)
	return nil
}

func consumerNack(_ *fisk.ParseContext, config *Config, c *consumerConfig) error {
	ctx, err := context.LoadContext(config.ContextName)
	if err != nil {
		return err
	}

	streamID, err := getFirstStream(ctx)
	if err != nil {
		return err
	}

	if config.AsCurl {
		req, err := api.BuildNackMessage(ctx, streamID, c.ConsumerID, c.AckToken)
		if err != nil {
			return err
		}
		curlCmd, err := formatCurl(req)
		if err != nil {
			return err
		}

		fmt.Println(curlCmd)

		return nil
	}

	err = api.NackMessage(ctx, streamID, c.ConsumerID, c.AckToken)
	if err != nil {
		return fmt.Errorf("failed to nack message: %w", err)
	}

	fmt.Printf("Message nacked: %s\n", c.AckToken)
	return nil
}

func consumerEdit(_ *fisk.ParseContext, config *Config, c *consumerConfig) error {
	ctx, err := context.LoadContext(config.ContextName)
	if err != nil {
		return err
	}

	streamID, err := getFirstStream(ctx)
	if err != nil {
		return err
	}

	consumer, err := api.FetchConsumerInfo(ctx, streamID, c.ConsumerID)
	if err != nil {
		return fmt.Errorf("could not load Consumer: %w", err)
	}

	// Create a new configuration based on the current one
	newConfig := *consumer // Dereference the pointer to create a copy

	// Update the new configuration with provided values
	if c.AckWaitMS != 0 {
		newConfig.AckWaitMS = c.AckWaitMS
	}
	if c.MaxAckPending != 0 {
		newConfig.MaxAckPending = c.MaxAckPending
	}
	if c.MaxDeliver != 0 {
		newConfig.MaxDeliver = c.MaxDeliver
	}
	if c.MaxWaiting != 0 {
		newConfig.MaxWaiting = c.MaxWaiting
	}

	// Compare the configurations
	diff := cmp.Diff(consumer, &newConfig)
	if diff == "" {
		fmt.Println("No difference in configuration")
		return nil
	}

	fmt.Printf("Differences (-old +new):\n%s", diff)

	if !c.Force {
		ok, err := askConfirmation(fmt.Sprintf("Really edit Consumer %s > %s", streamID, c.ConsumerID), false)
		if err != nil {
			return fmt.Errorf("could not obtain confirmation: %w", err)
		}
		if !ok {
			return nil
		}
	}

	updateOptions := api.ConsumerUpdateOptions{}

	// Update the options with provided values
	if c.AckWaitMS != 0 {
		updateOptions.AckWaitMS = c.AckWaitMS
	}
	if c.MaxAckPending != 0 {
		updateOptions.MaxAckPending = c.MaxAckPending
	}
	if c.MaxDeliver != 0 {
		updateOptions.MaxDeliver = c.MaxDeliver
	}
	if c.MaxWaiting != 0 {
		updateOptions.MaxWaiting = c.MaxWaiting
	}

	if config.AsCurl {
		req, err := api.BuildEditConsumer(ctx, streamID, c.ConsumerID, updateOptions)
		if err != nil {
			return err
		}
		curlCmd, err := formatCurl(req)
		if err != nil {
			return err
		}

		fmt.Println(curlCmd)

		return nil
	}

	updatedConsumer, err := api.EditConsumer(ctx, streamID, c.ConsumerID, updateOptions)
	if err != nil {
		return fmt.Errorf("failed to update consumer: %w", err)
	}

	fmt.Println("Consumer updated successfully:")
	displayConsumerInfo(updatedConsumer)

	return nil
}
