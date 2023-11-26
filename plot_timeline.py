import matplotlib.pyplot as plt
import json
import numpy as np
from collections import defaultdict

import os

def read_events_from_file(file_path):
    with open(file_path, 'r') as file:
        json_data = json.loads(file.read())

    transactions = json_data['transactions']
    transactions_per_client = defaultdict(list)
    for transaction in transactions:
        transactions_per_client[transaction['thread_id']].append(transaction)

    # now sort by client sequence number
    for l in transactions_per_client.values():
        l.sort(key=lambda x: x['thread_sequence_number'])
    return json_data, transactions_per_client


def delays_from_txs(txs):
    ret = []
    for tx in txs:
        if tx['response']['delay_ms'] > 0:
            ret.append(tx['response']['delay_ms'])
        else:
            ret.append(tx['response']['server_side_delay'])
    return ret


def plot_timeline(client_id, transactions, file_path):
    delays = delays_from_txs(transactions)
    rpm = [x['response']['current_req_per_min'] for x in transactions]

    # Create a sequence of numbers to represent the requests
    request_numbers = list(range(1, len(delays) + 1))

    # Create a figure and axis
    fig, ax = plt.subplots(figsize=(12, 5))

    # plot requ per min
    if 'all' in str(client_id).lower():
        ax.plot(request_numbers, rpm, marker='o', color="cyan", linestyle='-', markersize=1, label="Requests Per Minute")

    # Calculate the mean of delays
    mean_delay = np.mean(delays)
    max_rpm = np.max(rpm)


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
    ratio = len(x_blue) / len(x_red) if len(x_red) else 1
    print('ratio', ratio)

    # Add the ratio as text to the plot with a grey background and white foreground color
    ax.text(
            0.7, 0.85, f'Mean Delay: {mean_delay}ms\nMax Requests per Minute: {max_rpm: .2f}',
        transform=ax.transAxes,
        backgroundcolor='gray',  # Grey background color
        color='white',  # White foreground color
        bbox=dict(boxstyle='round,pad=0.4', facecolor='gray', edgecolor='none', alpha=0.8)  # Add a boxstyle for the background
    )


    # Add a legend to the plot at the upper right corner
    legend = ax.legend(loc='upper right')

    # Calculate the width and height of the legend box
    legend_bbox = legend.get_bbox_to_anchor()
    legend_width = legend_bbox.width
    legend_height = legend_bbox.height

    # Calculate the figure width and height
    fig_width, fig_height = fig.get_size_inches()

    # Set the bbox_to_anchor coordinates based on figure dimensions and legend dimensions
    legend_x = 1.0 + (legend_width / fig_width)  # Adjusted x-coordinate
    legend_y = 1.0  # Keep it at the upper-right corner

    ax.legend(loc='upper right', bbox_to_anchor=(1.3, legend_y))

    # Set labels for the x-axis (request sequence numbers)
    ax.set_xlabel('Request Sequence Number')
    ax.set_ylabel('API Delay [ms]')
    ax.set_title(f'Delays over time - rapid fire load ({file_path})')

    # Display the plot
    # plt.tight_layout()
    plt.savefig(f'{file_path}.{client_id}.png', bbox_inches='tight')


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        file_path = "testloop.out.json"  # Replace with the path to your JSON file
    else:
        file_path = sys.argv[1]
    json_data, tx_per_client = read_events_from_file(file_path)
    clients = list(tx_per_client.keys())
    for client in sorted(clients):
        plot_timeline(client, tx_per_client[client], file_path)

    # now plot ALL in ONE
    transactions = json_data['transactions']
    transactions.sort(key=lambda x: x['sequence_number'])
    plot_timeline('all_clients', transactions, file_path)


    # plot delays between all requests regardless of client
    txs_copy = []
    last_request_at = None
    transactions.sort(key=lambda x: x['response']['make_request_at_ms'])
    for tx in transactions:
        rat = tx['response']['make_request_at_ms']
        if last_request_at is None:
            delay_ms = tx['response']['delay_ms']
            if delay_ms == 0:
                delay_ms = tx['response']['server_side_delay']
            last_request_at = rat
        else:
            if last_request_at > rat:
                print("FCK")
                exit(1)
            delay_ms = rat - last_request_at
            last_request_at = rat
        txs_copy.append({
            'response': {
                'delay_ms': delay_ms,
                'server_side_delay': delay_ms,
                'current_req_per_min': tx['response']['current_req_per_min']
            }
        })
    plot_timeline('all_delays', txs_copy, file_path)


    # now write html
    with open(f'{file_path}.html', 'wt') as f:
        f.write('<html> <body>\n')
        f.write(f'<h1>Report for {file_path}</h1>\n')
        f.write('<h2>Server Config:</h2>\n')
        f.write(f'<pre>{json_data["apiguard_config"]}</pre>\n')
        f.write('<h2>Client Bot Config:</h2>\n')
        f.write(f'<pre>{json_data["config"]}</pre>\n')
        for client in sorted(clients):
            f.write(f'<h2>Client {client}:</h2>\n')
            f.write(f'<img src="{os.path.basename(file_path)}.{client}.png"/>\n')
        f.write('<h2>All Clients</h2>\n')
        f.write(f'<img src="{os.path.basename(file_path)}.all_clients.png"/>\n')
        f.write('<h2>Real Delays Between All Requests (including voluntary Client pauses)</h2>\n')
        f.write(f'<img src="{os.path.basename(file_path)}.all_delays.png"/>\n')
        f.write('</body> </html>')

    # also, write CSV
    with open(f'{file_path}.csv', 'wt') as f:
        fields = [
                'sequence_number', 
                'thread_id',
                'thread_sequence_number',
                'request_timestamp_ms',
                'response_timestamp_ms',
                'url',
                'handle_delay',
                'delay_ms',
                'current_req_per_min',
                'server_side_delay',
                'my_time_ms',
                'make_request_at_ms',
        ]
        f.write(','.join(fields) + '\n')
        for t in transactions:
            lf = []
            for fn in fields:
                try:
                    lf.append(str(t[fn]))
                except KeyError:
                    try:
                        lf.append(str(t['request'][fn]))
                    except KeyError:
                        lf.append(str(t['response'][fn]))
            f.write(','.join(lf) + '\n')
