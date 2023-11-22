import matplotlib.pyplot as plt
import json

import numpy as np

def read_events_from_file(file_path):
    """
    Read events from a file and extract server_side_delay values.

    Args:
        file_path (str): Path to the JSON file containing events.

    Returns:
        list of float: List of server_side_delay values.
    """
    delays = []

    with open(file_path, 'r') as file:
        for line in file:
            try:
                json_data = json.loads(line)
                server_side_delay = json_data.get("server_side_delay")
                if server_side_delay is not None:
                    delays.append(server_side_delay)
            except json.JSONDecodeError:
                # Handle invalid JSON lines if necessary
                pass

    return delays


def plot_timeline(delays):
    """
    Plot a timeline of server_side_delays.

    Args:
        delays (list of float): List of server_side_delay values.
    """
    # Create a sequence of numbers to represent the requests
    request_numbers = list(range(1, len(delays) + 1))

    # Create a figure and axis
    fig, ax = plt.subplots(figsize=(10, 5))

    # Don't plot the delays on the timeline
    # ax.plot(request_numbers, delays, marker='o', linestyle='-', markersize=1)

    # Calculate the mean of delays
    mean_delay = np.mean(delays)


    # Initialize lists to store x and y values for blue and red delays
    x_blue, y_blue = [], []
    x_red, y_red = [], []
    
    for i, delay in enumerate(delays):
        if delay <= mean_delay:
            x_blue.append(i + 1)
            y_blue.append(delay)
        else:
            x_red.append(i + 1)
            y_red.append(delay)


    # # Plot vertical lines connecting the blue markers
    ax.vlines(x_blue, ymin=0, ymax=y_blue, color='blue', alpha=0.1, linestyle='-', linewidths=0.5)
    # # Plot vertical lines connecting the red markers
    ax.vlines(x_red, ymin=mean_delay, ymax=y_red, color='red', alpha=0.1, linestyle='-', linewidths=0.5)

    # Plot delays <= mean in blue
    ax.scatter(x_blue, y_blue, marker='o', s=2, c='blue', label=f'Delays <= Mean ({len(x_blue)})')
    
    # Plot delays > mean in red
    ax.scatter(x_red, y_red, marker='o', s=2, c='red', label=f'Delays > Mean ({len(x_red)})')


    # Connect the markers with lines
    for i in range(1, len(request_numbers)):
        if i + 1 in x_blue:
            plt.plot([request_numbers[i - 1], request_numbers[i]], [delays[i - 1], delays[i]], color='blue', linestyle='-', linewidth=1, alpha=0.5)
        else:
            plt.plot([request_numbers[i - 1], request_numbers[i]], [delays[i - 1], delays[i]], color='red', linestyle='-', linewidth=1, alpha=0.5)





    # Add a horizontal mean line
    ax.axhline(y=mean_delay, color='r', linestyle='--', label=f'Mean Delay: {mean_delay:.2f}')

    # Calculate the ratio
    ratio = len(x_blue) / len(x_red)
    print('ratio', ratio)

    # Add the ratio as text to the plot with a grey background and white foreground color
    ax.text(
        0.7, 0.85, f'Ratio (<= mean / > mean): {ratio:.2f}',
        transform=ax.transAxes,
        backgroundcolor='gray',  # Grey background color
        color='white',  # White foreground color
        bbox=dict(boxstyle='round,pad=0.4', facecolor='gray', edgecolor='none', alpha=0.8)  # Add a boxstyle for the background
    )

    # Set labels for the x-axis (request sequence numbers)
    ax.set_xlabel('Request Sequence Number')
    ax.set_ylabel('API Delay [ms]')
    ax.set_title('Delays over time - rapid fire load')

    # Display the plot
    plt.tight_layout()
    plt.savefig('testloop.png')


# Example usage:
if __name__ == "__main__":
    file_path = "testloop.out.json"  # Replace with the path to your JSON file
    delays = read_events_from_file(file_path)
    plot_timeline(delays)
